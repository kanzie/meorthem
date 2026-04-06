import Foundation
import Combine

// 6h at 5s poll = 4,320 samples per target — enough for export/reports
private let kPingHistoryCapacity = 4_320
// 1h at 5s — WiFi stats change rarely
private let kWifiHistoryCapacity =    720

@MainActor
final class MetricStore: ObservableObject {

    // MARK: - Published snapshots
    @Published private(set) var latestPing: [UUID: PingResult] = [:]
    @Published private(set) var latestWifi: WiFiSnapshot?
    @Published private(set) var overallStatus: MetricStatus = .green
    @Published private(set) var networkFaultType: NetworkFaultType = .none

    // MARK: - Gateway ping
    private(set) var latestGatewayPing: PingResult?

    // MARK: - History
    private(set) var pingHistory: [UUID: CircularBuffer<PingResult>] = [:]
    private(set) var wifiHistory: CircularBuffer<WiFiSnapshot> = CircularBuffer(capacity: kWifiHistoryCapacity)
    private var statusHistory: CircularBuffer<MetricStatus> = CircularBuffer(capacity: 5)

    // MARK: - Hysteresis: consecutive non-green count per target
    private var consecutiveBadCount: [UUID: Int] = [:]

    // MARK: - Connection history (last 5 degradation events, persisted)
    @Published private(set) var connectionHistory: [ConnectionEvent] = []
    private var previousOverallStatus: MetricStatus = .green
    private static let kMaxConnectionEvents = 5
    private static let kHistoryUDKey = "metricStore.connectionHistory"

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        loadConnectionHistory()
    }

    // MARK: - Write

    func record(result: PingResult, for targetID: UUID) {
        latestPing[targetID] = result
        pingHistory[targetID, default: CircularBuffer(capacity: kPingHistoryCapacity)].append(result)

        let raw = MetricStatus.forPingResult(result, thresholds: settings.thresholds)
        if raw == .green {
            consecutiveBadCount[targetID] = 0
        } else {
            consecutiveBadCount[targetID] = (consecutiveBadCount[targetID] ?? 0) + 1
        }
        recomputeOverallStatus()
    }

    func recordWiFi(_ snapshot: WiFiSnapshot?) {
        latestWifi = snapshot
        if let s = snapshot { wifiHistory.append(s) }
    }

    func recordGatewayPing(_ result: PingResult?) {
        latestGatewayPing = result
        recomputeFaultType()
    }

    // MARK: - Derived

    func effectiveStatus(for targetID: UUID) -> MetricStatus {
        let raw = MetricStatus.forPingResult(latestPing[targetID], thresholds: settings.thresholds)
        return applyHysteresis(raw: raw, count: consecutiveBadCount[targetID, default: 0])
    }

    func latencyHistory(for targetID: UUID, last n: Int = 60) -> [Double] {
        pingHistory[targetID]?.last(n).compactMap(\.rtt) ?? []
    }

    func lossHistory(for targetID: UUID, last n: Int = 60) -> [Double] {
        pingHistory[targetID]?.last(n).map(\.lossPercent) ?? []
    }

    func sparklineData(for targetID: UUID, last n: Int = 12) -> [Double] {
        pingHistory[targetID]?.last(n).map { $0.rtt ?? 0 } ?? []
    }

    func recentOverallStatuses(last n: Int = 5) -> [MetricStatus] {
        statusHistory.last(n)
    }

    // MARK: - Private

    private func applyHysteresis(raw: MetricStatus, count: Int) -> MetricStatus {
        switch raw {
        case .green:  return .green
        case .yellow: return count >= 2 ? .yellow : .green
        case .red:    return count >= 3 ? .red : (count >= 2 ? .yellow : .green)
        }
    }

    private func recomputeOverallStatus() {
        var worst: MetricStatus = .green
        // Compute and collect effective statuses in one pass; reuse in fault-type logic
        // to avoid calling forPingResult() + applyHysteresis() a second time per target.
        var effectiveStatuses = [UUID: MetricStatus](minimumCapacity: latestPing.count)
        for (targetID, result) in latestPing {
            guard targetID != PingTarget.gatewayID else { continue }
            let raw = MetricStatus.forPingResult(result, thresholds: settings.thresholds)
            let effective = applyHysteresis(raw: raw, count: consecutiveBadCount[targetID, default: 0])
            effectiveStatuses[targetID] = effective
            if effective > worst { worst = effective }
        }

        let prev = previousOverallStatus
        previousOverallStatus = worst
        overallStatus = worst
        statusHistory.append(worst)

        // Connection history: detect green↔degraded transitions
        if prev == .green && worst != .green {
            openConnectionEvent(severity: worst)
        } else if prev != .green && worst == .green {
            closeActiveConnectionEvent()
        } else if prev != .green && worst != .green && prev != worst {
            // Severity escalated or de-escalated while still degraded — update active event
            updateActiveEventSeverity(worst)
        }

        recomputeFaultType(using: effectiveStatuses)
    }

    // MARK: - Connection history tracking

    private func openConnectionEvent(severity: MetricStatus) {
        let cause = computeDegradationCause()
        // Close any lingering open event (shouldn't normally exist)
        if let idx = connectionHistory.firstIndex(where: { $0.isActive }) {
            connectionHistory[idx].endTime = Date()
        }
        let event = ConnectionEvent(severity: severity, cause: cause)
        connectionHistory.insert(event, at: 0)
        if connectionHistory.count > Self.kMaxConnectionEvents {
            connectionHistory.removeLast()
        }
        saveConnectionHistory()
    }

    private func closeActiveConnectionEvent() {
        guard let idx = connectionHistory.firstIndex(where: { $0.isActive }) else { return }
        connectionHistory[idx].endTime = Date()
        saveConnectionHistory()
    }

    private func updateActiveEventSeverity(_ newSeverity: MetricStatus) {
        // Severity changed while degraded (e.g. yellow→red). We keep the original event
        // and just update its severity so the dot reflects the worst seen.
        guard let idx = connectionHistory.firstIndex(where: { $0.isActive }),
              newSeverity.rawValue > connectionHistory[idx].severityRaw else { return }
        let existing = connectionHistory[idx]
        connectionHistory[idx] = ConnectionEvent(severity: newSeverity,
                                                 startTime: existing.startTime,
                                                 cause: existing.cause)
        saveConnectionHistory()
    }

    private func computeDegradationCause() -> String {
        let t = settings.thresholds
        var parts: [String] = []

        let nonGatewayIDs = latestPing.keys.filter { $0 != PingTarget.gatewayID }

        let losses = nonGatewayIDs.map { latestPing[$0]?.lossPercent ?? 0 }
        if !losses.isEmpty {
            let avg = losses.reduce(0, +) / Double(losses.count)
            if avg >= t.lossYellowPct {
                parts.append(String(format: "packet loss (%.1f%%)", avg))
            }
        }

        let rtts = nonGatewayIDs.compactMap { latestPing[$0]?.rtt }
        if !rtts.isEmpty {
            let avg = rtts.reduce(0, +) / Double(rtts.count)
            if avg >= t.latencyYellowMs {
                parts.append(String(format: "high latency (%.0fms)", avg))
            }
        }

        let jitters = nonGatewayIDs.compactMap { latestPing[$0]?.jitter }
        if !jitters.isEmpty {
            let avg = jitters.reduce(0, +) / Double(jitters.count)
            if avg >= t.jitterYellowMs {
                parts.append(String(format: "high jitter (%.0fms)", avg))
            }
        }

        return parts.isEmpty ? "network degradation" : parts.joined(separator: ", ")
    }

    func clearConnectionHistory() {
        connectionHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.kHistoryUDKey)
    }

    private func saveConnectionHistory() {
        if let data = try? JSONEncoder().encode(connectionHistory) {
            UserDefaults.standard.set(data, forKey: Self.kHistoryUDKey)
        }
    }

    private func loadConnectionHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.kHistoryUDKey),
              let events = try? JSONDecoder().decode([ConnectionEvent].self, from: data)
        else { return }
        connectionHistory = events
        // Close any event left open from a previous session (app was force-quit during degradation)
        if let idx = connectionHistory.firstIndex(where: { $0.isActive }) {
            connectionHistory[idx].endTime = Date()
        }
    }

    /// Called from recomputeOverallStatus (statuses pre-computed) or standalone from recordGatewayPing.
    private func recomputeFaultType(using precomputed: [UUID: MetricStatus]? = nil) {
        guard overallStatus != .green else { networkFaultType = .none; return }
        guard let gw = latestGatewayPing else { networkFaultType = .none; return }

        let gatewayOk = gw.lossPercent < settings.thresholds.lossYellowPct
        // Use pre-computed statuses when available; otherwise compute fresh (gateway-only path).
        let statuses: [MetricStatus]
        if let precomputed {
            statuses = Array(precomputed.values)
        } else {
            statuses = latestPing.keys
                .filter { $0 != PingTarget.gatewayID }
                .map { effectiveStatus(for: $0) }
        }
        let allFailed = !statuses.isEmpty && statuses.allSatisfy { $0 == .red }

        if !gatewayOk {
            networkFaultType = .local
        } else if allFailed {
            networkFaultType = .isp
        } else {
            networkFaultType = .mixed
        }
    }

    // MARK: - Summary

    private static let _isoFormatter = ISO8601DateFormatter()

    func summaryText(targets: [PingTarget]) -> String {
        let df = MetricStore._isoFormatter
        var lines = ["Me Or Them Network Report — \(df.string(from: Date()))"]
        lines.append("")
        lines.append("PING TARGETS")
        for target in targets {
            lines.append("  \(target.label) (\(target.host)):  ")
            let recent = pingHistory[target.id]?.last(5) ?? []
            if recent.isEmpty {
                lines.append("    —")
            } else {
                for r in recent {
                    let rttStr = r.rtt.map { String(format: "%.1f ms", $0) } ?? "timeout"
                    let jitStr = r.jitter.map { String(format: "±%.1f ms", $0) } ?? "n/a"
                    lines.append("    \(rttStr)  loss \(String(format: "%.1f%%", r.lossPercent))  jitter \(jitStr)")
                }
            }
        }
        lines.append("")
        if let w = latestWifi {
            lines.append("WI-FI")
            lines.append("  SSID:    \(w.ssid)")
            lines.append("  RSSI:    \(w.rssi) dBm  (\(w.rssiQuality))")
        }
        lines.append("")
        lines.append("Overall status: \(overallStatus.label)")
        return lines.joined(separator: "\n")
    }
}
