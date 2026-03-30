import Foundation
import Combine

// 24h at 5s poll = 17,280 samples per target
private let kHistoryCapacity = 17_280

@MainActor
final class MetricStore: ObservableObject {

    // MARK: - Published snapshots (drive icon + menu updates)
    @Published private(set) var latestPing: [UUID: PingResult] = [:]
    @Published private(set) var latestWifi: WiFiSnapshot?
    @Published private(set) var overallStatus: MetricStatus = .green

    // MARK: - History (read by export + sparklines)
    private(set) var pingHistory: [UUID: CircularBuffer<PingResult>] = [:]
    private(set) var wifiHistory: CircularBuffer<WiFiSnapshot> = CircularBuffer(capacity: kHistoryCapacity)

    // MARK: - Settings reference for threshold evaluation
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Write methods (called from MonitoringEngine)

    func record(result: PingResult, for targetID: UUID) {
        latestPing[targetID] = result
        if pingHistory[targetID] == nil {
            pingHistory[targetID] = CircularBuffer(capacity: kHistoryCapacity)
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

    // MARK: - Derived

    func status(for targetID: UUID) -> MetricStatus {
        MetricStatus.forPingResult(latestPing[targetID], thresholds: settings.thresholds)
    }

    func latencyHistory(for targetID: UUID, last n: Int = 60) -> [Double] {
        pingHistory[targetID]?.last(n).compactMap(\.rtt) ?? []
    }

    func lossHistory(for targetID: UUID, last n: Int = 60) -> [Double] {
        pingHistory[targetID]?.last(n).map(\.lossPercent) ?? []
    }

    // MARK: - Private

    private func recomputeOverallStatus() {
        var worst: MetricStatus = .green
        for (_, result) in latestPing {
            let s = MetricStatus.forPingResult(result, thresholds: settings.thresholds)
            if s > worst { worst = s }
        }
        overallStatus = worst
    }

    // MARK: - Summary for clipboard report

    func summaryText(targets: [PingTarget]) -> String {
        let df = ISO8601DateFormatter()
        var lines = ["MeOrThem Network Report — \(df.string(from: Date()))"]
        lines.append("")
        lines.append("PING TARGETS")
        for target in targets {
            if let r = latestPing[target.id] {
                let rttStr  = r.rtt.map { String(format: "%.1f ms", $0) } ?? "timeout"
                let jitStr  = r.jitter.map { String(format: "±%.1f ms", $0) } ?? "n/a"
                lines.append("  \(target.label) (\(target.host)):  \(rttStr)  loss \(String(format: "%.1f%%", r.lossPercent))  jitter \(jitStr)")
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
        return lines.joined(separator: "\n")
    }
}

// MARK: - Format helper
private extension DefaultStringInterpolation {
    mutating func appendInterpolation(_ value: Double, format: String) {
        appendLiteral(String(format: format, value))
    }
}
