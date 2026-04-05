import Foundation
import Combine

// 24h at 5s poll = 17,280 samples per target
private let kPingHistoryCapacity = 17_280
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

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
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
        for (targetID, result) in latestPing {
            guard targetID != PingTarget.gatewayID else { continue }  // gateway handled separately
            let raw = MetricStatus.forPingResult(result, thresholds: settings.thresholds)
            let effective = applyHysteresis(raw: raw, count: consecutiveBadCount[targetID, default: 0])
            if effective > worst { worst = effective }
        }
        overallStatus = worst
        statusHistory.append(worst)
        recomputeFaultType()
    }

    private func recomputeFaultType() {
        guard overallStatus != .green else { networkFaultType = .none; return }
        guard let gw = latestGatewayPing else { networkFaultType = .none; return }

        let gatewayOk = gw.lossPercent < settings.thresholds.lossYellowPct
        let externalStatuses = latestPing.keys
            .filter { $0 != PingTarget.gatewayID }
            .map { effectiveStatus(for: $0) }
        let allFailed = !externalStatuses.isEmpty && externalStatuses.allSatisfy { $0 == .red }

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
