import Foundation
import MeOrThemCore

// MARK: - Data sufficiency tiers

enum DataSufficiency {
    case insufficient   // < 30 samples — do not show findings
    case limited        // 30–119 samples — show with warning
    case adequate       // 120–359 samples — show normally
    case strong         // ≥ 360 samples — show with high confidence

    init(sampleCount: Int) {
        switch sampleCount {
        case ..<30:   self = .insufficient
        case ..<120:  self = .limited
        case ..<360:  self = .adequate
        default:      self = .strong
        }
    }

    var multiplier: Double {
        switch self {
        case .insufficient: return 0.0
        case .limited:      return 0.5
        case .adequate:     return 0.8
        case .strong:       return 1.0
        }
    }

    var label: String {
        switch self {
        case .insufficient: return "Insufficient data"
        case .limited:      return "Limited data"
        case .adequate:     return "Adequate data"
        case .strong:       return "Strong dataset"
        }
    }
}

// MARK: - Finding model

struct NetworkFinding: Identifiable {
    enum Category: String {
        case latency    = "Latency"
        case packetLoss = "Packet Loss"
        case jitter     = "Jitter"
        case wifi       = "Wi-Fi Signal"
        case bandwidth  = "Bandwidth"
    }

    let id = UUID()
    let category: Category
    let title: String
    let detail: String
    /// 0–1. Accounts for data sufficiency and session mixing.
    let confidence: Double

    var confidenceLabel: String {
        switch confidence {
        case 0.80...: return "High"
        case 0.55...: return "Medium"
        default:      return "Low"
        }
    }
}

// MARK: - Session summary (input to the analyzer)

struct SessionAnalysisInput {
    let session: SQLiteStore.NetworkSessionRow
    /// Ping rows for user-configured external targets only (gateway excluded).
    let pingRows: [SQLiteStore.PingRow]
    /// Ping rows for the local gateway target — used to distinguish local vs. ISP faults.
    let gatewayPingRows: [SQLiteStore.PingRow]
    let wifiRows: [SQLiteStore.WiFiRow]
    let speedtestRows: [SQLiteStore.SpeedtestRow]
}

// MARK: - Analyzer

final class NetworkAnalyzer {

    // Thresholds used to decide whether a metric is "elevated"
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Runs all five pattern checks on the given session data and returns findings.
    /// Only medium- and high-confidence findings (confidence ≥ 0.40) are returned.
    func analyze(_ input: SessionAnalysisInput) -> [NetworkFinding] {
        let pingCount = input.pingRows.count
        let sufficiency = DataSufficiency(sampleCount: pingCount)
        guard sufficiency != .insufficient else { return [] }

        var findings: [NetworkFinding] = []

        findings += checkLatency(input, sufficiency: sufficiency)
        findings += checkPacketLoss(input, sufficiency: sufficiency)
        findings += checkJitter(input, sufficiency: sufficiency)
        findings += checkWiFiSignal(input, sufficiency: sufficiency)
        findings += checkBandwidth(input, sufficiency: sufficiency)

        return findings.filter { $0.confidence >= 0.40 }
    }

    // MARK: - Pattern 1: Elevated latency

    private func checkLatency(_ input: SessionAnalysisInput,
                               sufficiency: DataSufficiency) -> [NetworkFinding] {
        let rtts = input.pingRows.compactMap(\.rttMs)
        guard rtts.count >= 10 else { return [] }

        let avg    = rtts.reduce(0, +) / Double(rtts.count)
        let thresh = settings.thresholds.latencyYellowMs

        guard avg >= thresh else { return [] }

        // Check for time-of-day correlation: bucket by hour and flag hours >40% above avg
        let sorted = input.pingRows.sorted { $0.timestamp < $1.timestamp }
        let hourBuckets = Dictionary(grouping: sorted) { row -> Int in
            Calendar.current.component(.hour, from: row.timestamp)
        }
        var peakHours: [Int] = []
        for (hour, rows) in hourBuckets {
            let hrs = rows.compactMap(\.rttMs)
            guard hrs.count >= 3 else { continue }
            let hAvg = hrs.reduce(0, +) / Double(hrs.count)
            if hAvg > avg * 1.4 { peakHours.append(hour) }
        }

        // Gateway attribution: compare gateway latency to external target latency.
        // If the gateway is also elevated, the bottleneck is local (router/LAN/WiFi).
        // If the gateway is clean while external targets are high, it's upstream (ISP).
        let attribution: String
        var confidenceBoost = 0.0
        let gwRtts = input.gatewayPingRows.compactMap(\.rttMs)
        if gwRtts.count >= 5 {
            let gwAvg = gwRtts.reduce(0, +) / Double(gwRtts.count)
            if gwAvg >= thresh {
                attribution = "Gateway latency is also elevated (avg %.0f ms), suggesting the bottleneck is on the local network or router."
                confidenceBoost = 0.10
            } else {
                attribution = "Gateway responds normally (avg %.0f ms), suggesting the bottleneck is upstream — ISP or routing path."
                confidenceBoost = 0.10
            }
        } else {
            attribution = ""
        }

        let base: Double = avg >= thresh * 2 ? 0.85 : 0.65
        let confidence   = min(1.0, (base + confidenceBoost) * sufficiency.multiplier)

        var detail: String
        if !peakHours.isEmpty {
            let hrs = peakHours.sorted().map { String(format: "%02d:00", $0) }.joined(separator: ", ")
            detail = String(format: "Average RTT %.1f ms (threshold %.0f ms). Elevated during: %@.", avg, thresh, hrs)
        } else {
            detail = String(format: "Average RTT %.1f ms sustained above threshold (%.0f ms).", avg, thresh)
        }
        if !attribution.isEmpty, let gwAvg = gwRtts.isEmpty ? nil : gwRtts.reduce(0, +) / Double(gwRtts.count) {
            detail += " " + String(format: attribution, gwAvg)
        }

        return [NetworkFinding(category: .latency,
                               title: "Elevated latency",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 2: Packet loss

    private func checkPacketLoss(_ input: SessionAnalysisInput,
                                  sufficiency: DataSufficiency) -> [NetworkFinding] {
        guard !input.pingRows.isEmpty else { return [] }

        let losses  = input.pingRows.map(\.lossPct)
        let avgLoss = losses.reduce(0, +) / Double(losses.count)
        let thresh  = settings.thresholds.lossYellowPct

        guard avgLoss >= thresh else { return [] }

        // Burst vs steady: count runs of consecutive non-zero loss
        var burstCount   = 0
        var inBurst      = false
        var burstLengths = [Int]()
        var currentBurst = 0
        for l in losses {
            if l > 0 {
                if !inBurst { inBurst = true; currentBurst = 0; burstCount += 1 }
                currentBurst += 1
            } else {
                if inBurst { burstLengths.append(currentBurst); inBurst = false }
            }
        }
        if inBurst { burstLengths.append(currentBurst) }
        let avgBurst = burstLengths.isEmpty ? 1.0
            : Double(burstLengths.reduce(0, +)) / Double(burstLengths.count)

        // Gateway attribution: if the gateway also drops packets at a similar rate,
        // the fault is local. If the gateway is clean, the fault is upstream.
        let gwLosses = input.gatewayPingRows.map(\.lossPct)
        var attribution = ""
        var confidenceBoost = 0.0
        if gwLosses.count >= 5 {
            let gwAvgLoss = gwLosses.reduce(0, +) / Double(gwLosses.count)
            if gwAvgLoss >= thresh {
                attribution = String(format: " Gateway also drops %.1f%% of packets, pointing to the local network or router as the likely cause.", gwAvgLoss)
                confidenceBoost = 0.10
            } else {
                attribution = " Gateway responds without loss, suggesting the drops occur upstream — ISP or internet routing."
                confidenceBoost = 0.10
            }
        }

        let base: Double = avgLoss >= thresh * 2 ? 0.90 : 0.70
        let confidence   = min(1.0, (base + confidenceBoost) * sufficiency.multiplier)

        let style = avgBurst > 3 ? "sustained bursts" : "sporadic drops"
        let detail = String(format: "Average loss %.1f%% (%@). %d loss event(s) detected.",
                            avgLoss, style, burstCount) + attribution

        return [NetworkFinding(category: .packetLoss,
                               title: "Packet loss detected",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 3: Jitter

    private func checkJitter(_ input: SessionAnalysisInput,
                              sufficiency: DataSufficiency) -> [NetworkFinding] {
        let jitters = input.pingRows.compactMap(\.jitterMs)
        guard jitters.count >= 10 else { return [] }

        let avg    = jitters.reduce(0, +) / Double(jitters.count)
        let thresh = settings.thresholds.jitterYellowMs

        guard avg >= thresh else { return [] }

        let base: Double = avg >= thresh * 2 ? 0.80 : 0.60
        let confidence   = base * sufficiency.multiplier

        let detail = String(format: "Average jitter %.1f ms (threshold %.0f ms). High jitter typically indicates network congestion or an unstable wireless connection.", avg, thresh)

        return [NetworkFinding(category: .jitter,
                               title: "High jitter",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 4: Wi-Fi signal degradation

    private func checkWiFiSignal(_ input: SessionAnalysisInput,
                                  sufficiency: DataSufficiency) -> [NetworkFinding] {
        guard input.wifiRows.count >= 10 else { return [] }

        let rssis   = input.wifiRows.map { Double($0.rssi) }
        let avgRSSI = rssis.reduce(0, +) / Double(rssis.count)

        let snrs   = input.wifiRows.map { Double($0.snr) }
        let avgSNR = snrs.reduce(0, +) / Double(snrs.count)

        // RSSI standard deviation — measures signal instability.
        let rssiVariance = rssis.map { pow($0 - avgRSSI, 2) }.reduce(0, +) / Double(rssis.count)
        let rssiStdDev   = sqrt(rssiVariance)

        // WiFi sufficiency uses its own row count
        let wifiSufficiency = DataSufficiency(sampleCount: input.wifiRows.count)

        // SNR adjusts confidence: noisy environment (low SNR) makes signal quality worse
        let snrBoost: Double = avgSNR < 20 ? 0.10 : (avgSNR > 30 ? -0.05 : 0.0)

        var findings: [NetworkFinding] = []

        // Finding A: Weak average signal (avgRSSI below -65 dBm)
        if avgRSSI < -65 {
            let base: Double
            switch avgRSSI {
            case ..<(-80): base = 0.90
            case ..<(-72): base = 0.75
            default:       base = 0.55
            }
            let confidence = min(1.0, (base + snrBoost) * wifiSufficiency.multiplier)
            let quality    = avgRSSI < -80 ? "very poor" : avgRSSI < -72 ? "poor" : "marginal"

            let varianceNote = rssiStdDev > 8.0
                ? String(format: " Signal also varies widely (±%.0f dBm), compounding the impact.", rssiStdDev)
                : ""
            let detail = String(format: "Average signal %.0f dBm (%@), SNR %.0f dB.%@ Consider moving closer to your router or switching bands.",
                                avgRSSI, quality, avgSNR, varianceNote)

            findings.append(NetworkFinding(category: .wifi,
                                           title: "Weak Wi-Fi signal",
                                           detail: detail,
                                           confidence: confidence))
        }

        // Finding B: Unstable signal (high variance even when average looks acceptable)
        // Only emit this as a standalone finding if avgRSSI is acceptable (>= -65).
        // When avgRSSI is already poor, the variance note is folded into Finding A above.
        if rssiStdDev > 8.0 && avgRSSI >= -65 {
            let base: Double = rssiStdDev > 15.0 ? 0.80 : 0.65
            let confidence   = min(1.0, (base + snrBoost) * wifiSufficiency.multiplier)
            let detail = String(format: "Signal varied by ±%.0f dBm around an average of %.0f dBm. Instability typically indicates interference, obstacles between the device and router, or the device roaming between access points.",
                                rssiStdDev, avgRSSI)

            findings.append(NetworkFinding(category: .wifi,
                                           title: "Unstable Wi-Fi signal",
                                           detail: detail,
                                           confidence: confidence))
        }

        return findings
    }

    // MARK: - Pattern 5: Bandwidth anomaly

    private func checkBandwidth(_ input: SessionAnalysisInput,
                                 sufficiency: DataSufficiency) -> [NetworkFinding] {
        let speeds = input.speedtestRows
        guard speeds.count >= 2 else { return [] }

        let downloads = speeds.map(\.downloadMbps)
        let avgDl     = downloads.reduce(0, +) / Double(downloads.count)
        let minDl     = downloads.min() ?? 0
        let maxDl     = downloads.max() ?? 0

        // Flag if the minimum is less than half the maximum — high variability
        guard maxDl > 0, minDl / maxDl < 0.5 else { return [] }

        // Sufficiency based on number of speed tests (not ping samples)
        let speedSufficiency = DataSufficiency(sampleCount: speeds.count * 20) // scale up: 18 tests ≈ adequate
        let base: Double     = minDl / maxDl < 0.25 ? 0.75 : 0.55
        let confidence       = base * speedSufficiency.multiplier

        let detail = String(format: "Download ranged from %.1f to %.1f Mbps (avg %.1f Mbps). High variability may indicate congestion or an unstable connection.", minDl, maxDl, avgDl)

        return [NetworkFinding(category: .bandwidth,
                               title: "Variable download speed",
                               detail: detail,
                               confidence: confidence)]
    }
}
