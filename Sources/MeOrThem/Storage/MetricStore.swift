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

    // MARK: - Hysteresis: consecutive non-green count per target
    // Yellow requires ≥2 consecutive bad polls; red requires ≥3.
    private var consecutiveBadCount: [UUID: Int] = [:]

    // MARK: - Settings reference for threshold evaluation
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Write methods (called from MonitoringEngine)

    func record(result: PingResult, for targetID: UUID) {
        latestPing[targetID] = result
        if pingHistory[targetID] == nil {
            pingHistory[targetID] = CircularBuffer(capacity: kPingHistoryCapacity)
        }
        pingHistory[targetID]!.append(result)

        // Update hysteresis counter
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

    /// Returns the effective (hysteresis-adjusted) status for a target.
    /// Yellow requires 2+ consecutive bad polls; red requires 3+.
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

    /// Sparkline data: last N RTT values for a target (nil = timeout replaced by 0 for display).
    func sparklineData(for targetID: UUID, last n: Int = 12) -> [Double] {
        pingHistory[targetID]?.last(n).map { $0.rtt ?? 0 } ?? []
    }

    /// Returns the last N overall status values in chronological order (oldest first).
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
        overallStatus = worst
        statusHistory.append(worst)
        recomputeFaultType(using: effectiveStatuses)
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
            lines.append("  SSID:    \(w.ssid)")
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
