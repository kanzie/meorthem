import Foundation
import Combine

// 6h at 5s poll = 4,320 samples per target — enough for export/reports
private let kPingHistoryCapacity = 4_320
// 1h of WiFi snapshots (changes rarely — RSSI, channel, SSID)
private let kWifiHistoryCapacity = 720

@MainActor
final class MetricStore: ObservableObject {

    // MARK: - Published snapshots (drive icon + menu updates)
    @Published private(set) var latestPing: [UUID: PingResult] = [:]
    @Published private(set) var latestWifi: WiFiSnapshot?
    @Published private(set) var overallStatus: MetricStatus = .green
    @Published private(set) var networkFaultType: NetworkFaultType = .none

    // MARK: - Gateway ping (set by MonitoringEngine each tick)
    private(set) var latestGatewayPing: PingResult?
    @Published private(set) var latestGatewayIP: String?

    // MARK: - History (read by export + sparklines)
    private(set) var pingHistory: [UUID: CircularBuffer<PingResult>] = [:]
    private(set) var wifiHistory: CircularBuffer<WiFiSnapshot> = CircularBuffer(capacity: kWifiHistoryCapacity)
    private var statusHistory: CircularBuffer<MetricStatus> = CircularBuffer(capacity: 5)

    // MARK: - Connection history (last 5 degradation events, persisted)
    @Published private(set) var connectionHistory: [ConnectionEvent] = []
    private var previousOverallStatus: MetricStatus = .green
    private static let kMaxConnectionEvents = 5
    private static let kHistoryUDKey = "metricStore.connectionHistory"

    // MARK: - Settings reference for threshold evaluation
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        loadConnectionHistory()
    }

    // MARK: - Write methods (called from MonitoringEngine)

    func record(result: PingResult, for targetID: UUID) {
        latestPing[targetID] = result
        if pingHistory[targetID] == nil {
            pingHistory[targetID] = CircularBuffer(capacity: kPingHistoryCapacity)
        }
        pingHistory[targetID]!.append(result)
        recomputeOverallStatus()
    }

    func recordWiFi(_ snapshot: WiFiSnapshot?) {
        latestWifi = snapshot
        if let s = snapshot {
            wifiHistory.append(s)
        }
    }

    func recordGatewayPing(_ result: PingResult?, gatewayIP: String? = nil) {
        if let ip = gatewayIP { latestGatewayIP = ip }
        latestGatewayPing = result
        recomputeFaultType()
    }

    // MARK: - Derived

    /// Returns the window-averaged status for a target.
    func effectiveStatus(for targetID: UUID) -> MetricStatus {
        windowedStatus(for: targetID)
    }

    func latencyHistory(for targetID: UUID, last n: Int = 60) -> [Double] {
        pingHistory[targetID]?.last(n).compactMap(\.rtt) ?? []
    }

    func lossHistory(for targetID: UUID, last n: Int = 60) -> [Double] {
        pingHistory[targetID]?.last(n).map(\.lossPercent) ?? []
    }

    /// Sparkline data: last N RTT values for a target (nil = timeout replaced by 0 for display).
    func sparklineData(for targetID: UUID, last n: Int = 12) -> [Double] {
        pingHistory[targetID]?.last(n).map { $0.rtt ?? 0 } ?? []
    }

    /// Returns the last N overall status values in chronological order (oldest first).
    func recentOverallStatuses(last n: Int = 5) -> [MetricStatus] {
        statusHistory.last(n)
    }

    // MARK: - Private

    /// Returns the window-averaged status for a target.
    /// Each metric is averaged over its configured evaluation window, expressed as
    /// sample count = ceil(windowSecs / pollIntervalSecs). This naturally filters
    /// brief single-poll spikes (AWDL, roaming) without needing a separate debounce.
    private func windowedStatus(for targetID: UUID) -> MetricStatus {
        guard let history = pingHistory[targetID] else { return .red }
        let t    = settings.thresholds
        let poll = settings.pollIntervalSecs

        let latencyN = max(1, Int(ceil(settings.latencyWindowSecs / poll)))
        let lossN    = max(1, Int(ceil(settings.lossWindowSecs    / poll)))
        let jitterN  = max(1, Int(ceil(settings.jitterWindowSecs  / poll)))

        let samples = history.last(max(latencyN, max(lossN, jitterN)))
        let lossSlice    = Array(samples.suffix(lossN)).map(\.lossPercent)
        let latencySlice = Array(samples.suffix(latencyN)).compactMap(\.rtt)
        let jitterSlice  = Array(samples.suffix(jitterN)).compactMap(\.jitter)

        return MetricStatus.forWindow(loss: lossSlice, latency: latencySlice,
                                      jitter: jitterSlice, thresholds: t)
    }

    private func recomputeOverallStatus() {
        var worst: MetricStatus = .green
        // Compute and collect windowed statuses in one pass; reuse in fault-type logic
        // to avoid re-reading the circular buffer a second time per target.
        var effectiveStatuses = [UUID: MetricStatus](minimumCapacity: latestPing.count)
        for targetID in latestPing.keys {
            guard targetID != PingTarget.gatewayID else { continue }
            let effective = windowedStatus(for: targetID)
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
            updateActiveEventSeverity(worst)
        }

        recomputeFaultType(using: effectiveStatuses)
    }

    // MARK: - Connection history tracking

    private func openConnectionEvent(severity: MetricStatus) {
        let cause = computeDegradationCause()
        if let idx = connectionHistory.firstIndex(where: { $0.isActive }) {
            connectionHistory[idx].endTime = Date()
        }
        connectionHistory.insert(ConnectionEvent(severity: severity, cause: cause), at: 0)
        if connectionHistory.count > Self.kMaxConnectionEvents { connectionHistory.removeLast() }
        saveConnectionHistory()
    }

    private func closeActiveConnectionEvent() {
        guard let idx = connectionHistory.firstIndex(where: { $0.isActive }) else { return }
        connectionHistory[idx].endTime = Date()
        saveConnectionHistory()
    }

    private func updateActiveEventSeverity(_ newSeverity: MetricStatus) {
        guard let idx = connectionHistory.firstIndex(where: { $0.isActive }),
              newSeverity.rawValue > connectionHistory[idx].severityRaw else { return }
        let e = connectionHistory[idx]
        connectionHistory[idx] = ConnectionEvent(severity: newSeverity, startTime: e.startTime, cause: e.cause)
        saveConnectionHistory()
    }

    private func computeDegradationCause() -> String {
        let t = settings.thresholds
        var parts: [String] = []
        let ids = latestPing.keys.filter { $0 != PingTarget.gatewayID }

        let losses = ids.map { latestPing[$0]?.lossPercent ?? 0 }
        if !losses.isEmpty {
            let avg = losses.reduce(0, +) / Double(losses.count)
            if avg >= t.lossYellowPct { parts.append(String(format: "packet loss (%.1f%%)", avg)) }
        }
        let rtts = ids.compactMap { latestPing[$0]?.rtt }
        if !rtts.isEmpty {
            let avg = rtts.reduce(0, +) / Double(rtts.count)
            if avg >= t.latencyYellowMs { parts.append(String(format: "high latency (%.0fms)", avg)) }
        }
        let jitters = ids.compactMap { latestPing[$0]?.jitter }
        if !jitters.isEmpty {
            let avg = jitters.reduce(0, +) / Double(jitters.count)
            if avg >= t.jitterYellowMs { parts.append(String(format: "high jitter (%.0fms)", avg)) }
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
        if let idx = connectionHistory.firstIndex(where: { $0.isActive }) {
            connectionHistory[idx].endTime = Date()
        }
    }

    /// Called from recomputeOverallStatus (statuses pre-computed) or standalone from recordGatewayPing.
    private func recomputeFaultType(using precomputed: [UUID: MetricStatus]? = nil) {
        guard overallStatus != .green else { networkFaultType = .none; return }
        guard let gw = latestGatewayPing else {
            networkFaultType = .none
            return
        }

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
        let allExternalFailed = !statuses.isEmpty && statuses.allSatisfy { $0 == .red }

        if !gatewayOk {
            networkFaultType = .local
        } else if allExternalFailed {
            networkFaultType = .isp
        } else {
            networkFaultType = .mixed
        }
    }

    // MARK: - Summary for clipboard report

    private static let _localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    func summaryText(targets: [PingTarget]) -> String {
        var lines = ["Me Or Them Network Report — \(Self._localFormatter.string(from: Date()))"]
        lines.append("")
        lines.append("PING TARGETS")
        for target in targets {
            lines.append("  \(target.label) (\(target.host)):  ")
            let recent = pingHistory[target.id]?.last(5) ?? []
            if recent.isEmpty {
                lines.append("    —")
            } else {
                for r in recent {
                    let ts     = Self._localFormatter.string(from: r.timestamp)
                    let rttStr = r.rtt.map { String(format: "%.1f ms", $0) } ?? "timeout"
                    let jitStr = r.jitter.map { String(format: "±%.1f ms", $0) } ?? "n/a"
                    lines.append("    [\(ts)]  \(rttStr)  loss \(String(format: "%.1f%%", r.lossPercent))  jitter \(jitStr)")
                }
            }
        }
        lines.append("")
        if let w = latestWifi {
            lines.append("WI-FI")
            lines.append("  RSSI:    \(w.rssi) dBm  (\(w.rssiQuality))")
            lines.append("  SNR:     \(w.snr) dB")
            lines.append("  Channel: \(w.channelNumber)  (\(w.channelBandGHz, format: "%.1f") GHz)")
            lines.append("  TX Rate: \(String(format: "%.0f Mbps", w.txRateMbps))")
        }
        lines.append("")
        lines.append("Overall status: \(overallStatus.label)")
        if networkFaultType != .none {
            lines.append(networkFaultType.displayLabel)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Format helper
private extension DefaultStringInterpolation {
    mutating func appendInterpolation(_ value: Double, format: String) {
        appendLiteral(String(format: format, value))
    }
}
