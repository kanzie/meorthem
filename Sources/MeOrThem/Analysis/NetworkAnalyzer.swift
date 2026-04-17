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
        case latency      = "Latency"
        case packetLoss   = "Packet Loss"
        case jitter       = "Jitter"
        case wifi         = "Wi-Fi Signal"
        case bandwidth    = "Bandwidth"
        case connectivity = "Connectivity"
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
    /// Flat list used by single-target patterns (latency, loss, jitter).
    let pingRows: [SQLiteStore.PingRow]
    /// Same rows as `pingRows` but keyed by target UUID, used by divergence analysis.
    let pingRowsByTarget: [UUID: [SQLiteStore.PingRow]]
    /// Ping rows for the local gateway target — used to distinguish local vs. ISP faults.
    let gatewayPingRows: [SQLiteStore.PingRow]
    let wifiRows: [SQLiteStore.WiFiRow]
    let speedtestRows: [SQLiteStore.SpeedtestRow]
    /// Legacy single-resolver DNS samples (one per ~30 s). Retained for backward compatibility
    /// with existing sessions; new sessions use `dnsResolverRows` instead.
    let dnsRows: [SQLiteStore.DnsRow]
    /// Multi-resolver DNS probe results. Used by patterns 10a–10e.
    var dnsResolverRows: [SQLiteStore.DNSResolverRow] = []
    /// Interface error/drop delta samples (one per ~30 s). Used to detect hardware-level issues.
    let interfaceErrorRows: [SQLiteStore.InterfaceErrorRow]
    /// MTU probe results (~every 2.5 min). Used to detect path fragmentation.
    let mtuRows: [SQLiteStore.MTURow]
}

// MARK: - Analyzer

final class NetworkAnalyzer: @unchecked Sendable {

    // Values snapshotted from AppSettings on the MainActor before any detached task;
    // stored as plain value types so NetworkAnalyzer itself needs no actor isolation.
    private let thresholds:      Thresholds
    private let pingTargetLabels: [UUID: String]   // id → display label

    /// Initialise with snapshots captured on the @MainActor before entering a detached task.
    @MainActor
    init(settings: AppSettings) {
        self.thresholds      = settings.thresholds
        self.pingTargetLabels = Dictionary(
            uniqueKeysWithValues: settings.pingTargets.map { ($0.id, $0.label) })
    }

    /// Convenience init for contexts where settings are already captured as value types.
    init(thresholds: Thresholds, pingTargetLabels: [UUID: String]) {
        self.thresholds       = thresholds
        self.pingTargetLabels = pingTargetLabels
    }

    /// Runs all pattern checks on the given session data and returns findings.
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
        findings += checkSessionFaultProfile(input, sufficiency: sufficiency)
        findings += checkWiFiLatencyCorrelation(input, sufficiency: sufficiency)
        findings += checkTargetDivergence(input, sufficiency: sufficiency)
        findings += checkBufferbloat(input, sufficiency: sufficiency)
        findings += checkDNS(input, sufficiency: sufficiency)       // legacy fallback
        findings += checkDNSMultiResolver(input)                     // patterns 10a–10e
        findings += checkInterfaceErrors(input, sufficiency: sufficiency)
        findings += checkMTU(input, sufficiency: sufficiency)

        return findings.filter { $0.confidence >= 0.40 }
    }

    // MARK: - Pattern 1: Elevated latency

    private func checkLatency(_ input: SessionAnalysisInput,
                               sufficiency: DataSufficiency) -> [NetworkFinding] {
        let rtts = input.pingRows.compactMap(\.rttMs)
        guard rtts.count >= 10 else { return [] }

        let avg    = rtts.reduce(0, +) / Double(rtts.count)
        let thresh = thresholds.latencyYellowMs

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
        let thresh  = thresholds.lossYellowPct

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
        // Inter-poll jitter: std dev of the per-poll average RTT sequence.
        // This captures how consistently the network performs across polls — which
        // is what the user actually experiences — rather than the intra-poll std dev
        // of 3 ICMP packets (which has high sampling error with so few samples).
        let rtts = input.pingRows.compactMap(\.rttMs)
        guard rtts.count >= 10 else { return [] }

        let rttMean     = rtts.reduce(0, +) / Double(rtts.count)
        let rttVariance = rtts.map { pow($0 - rttMean, 2) }.reduce(0, +) / Double(rtts.count)
        let interPollJitter = sqrt(rttVariance)

        let thresh = thresholds.jitterYellowMs
        guard interPollJitter >= thresh else { return [] }

        // Also check average intra-poll jitter (std dev of 3 packets per poll).
        // When both are high → severe instability; when only inter-poll is high → congestion pattern.
        let intraPollJitters = input.pingRows.compactMap(\.jitterMs)
        let avgIntraPoll: Double? = intraPollJitters.count >= 5
            ? intraPollJitters.reduce(0, +) / Double(intraPollJitters.count)
            : nil

        let base: Double = interPollJitter >= thresh * 2 ? 0.80 : 0.60
        let confidence   = base * sufficiency.multiplier

        let pattern: String
        if let intra = avgIntraPoll, intra >= thresh {
            pattern = "Instability is present both within individual polls and across polls, suggesting a severely unstable connection."
        } else {
            pattern = "Latency drifts significantly between polls, consistent with intermittent congestion or buffering on the path."
        }

        let detail = String(format: "Latency varied ±%.1f ms between polls (threshold %.0f ms). %@",
                            interPollJitter, thresh, pattern)

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

    // MARK: - Pattern 6: Session fault profile (local vs ISP attribution)
    //
    // Bins all ping rows into per-minute slots and classifies each degraded minute
    // as local (gateway also degraded), upstream (gateway clean), or both.
    // Emits a connectivity finding that summarises where problems occurred during
    // the session — even when individual metric thresholds were not crossed.

    private func checkSessionFaultProfile(_ input: SessionAnalysisInput,
                                          sufficiency: DataSufficiency) -> [NetworkFinding] {
        guard input.gatewayPingRows.count >= 10,
              input.pingRows.count >= 10 else { return [] }

        let lossThresh = thresholds.lossYellowPct
        let latThresh  = thresholds.latencyYellowMs

        // Build per-minute sets: which minutes had degraded external targets / gateway
        func degradedMinutes(rows: [SQLiteStore.PingRow]) -> Set<Int> {
            var mins = Set<Int>()
            // Group rows by minute bucket
            let byMinute = Dictionary(grouping: rows) { row in
                Int(row.timestamp.timeIntervalSince1970 / 60)
            }
            for (minute, bucket) in byMinute {
                let losses = bucket.map(\.lossPct)
                let rtts   = bucket.compactMap(\.rttMs)
                let avgLoss = losses.reduce(0, +) / Double(losses.count)
                let avgRTT  = rtts.isEmpty ? 0.0 : rtts.reduce(0, +) / Double(rtts.count)
                if avgLoss >= lossThresh || avgRTT >= latThresh { mins.insert(minute) }
            }
            return mins
        }

        let externalDegraded = degradedMinutes(rows: input.pingRows)
        let gatewayDegraded  = degradedMinutes(rows: input.gatewayPingRows)

        // Only minutes where external targets were degraded matter for diagnosis
        guard externalDegraded.count >= 5 else { return [] }

        let localFaultMins    = externalDegraded.intersection(gatewayDegraded).count
        let upstreamFaultMins = externalDegraded.subtracting(gatewayDegraded).count
        let totalDegraded     = externalDegraded.count

        let localFraction    = Double(localFaultMins)    / Double(totalDegraded)
        let upstreamFraction = Double(upstreamFaultMins) / Double(totalDegraded)

        let title: String
        let detail: String
        let base: Double

        switch (localFraction, upstreamFraction) {
        case let (l, _) where l >= 0.65:
            title  = "Primarily local network issues"
            detail = String(format: "In %.0f%% of degraded periods (%d of %d minutes), the gateway was also affected, indicating the local network or router as the likely bottleneck. Check router performance, cable connections, or WiFi interference.",
                            localFraction * 100, localFaultMins, totalDegraded)
            base   = localFraction >= 0.85 ? 0.85 : 0.70

        case let (_, u) where u >= 0.65:
            title  = "Primarily upstream / ISP issues"
            detail = String(format: "In %.0f%% of degraded periods (%d of %d minutes), the gateway responded normally while external targets degraded, pointing to the ISP or internet routing as the likely cause.",
                            upstreamFraction * 100, upstreamFaultMins, totalDegraded)
            base   = upstreamFraction >= 0.85 ? 0.85 : 0.70

        default:
            title  = "Mixed local and upstream issues"
            detail = String(format: "Degradation was split: %.0f%% local (%d min) and %.0f%% upstream (%d min). The connection may have experienced both router/LAN problems and ISP-side issues during this session.",
                            localFraction * 100, localFaultMins,
                            upstreamFraction * 100, upstreamFaultMins)
            base   = 0.60
        }

        let confidence = min(1.0, base * sufficiency.multiplier)
        return [NetworkFinding(category: .connectivity, title: title, detail: detail, confidence: confidence)]
    }

    // MARK: - Pattern 7: WiFi–latency correlation
    //
    // Time-aligns WiFi RSSI samples with external ping RTTs and computes the
    // Pearson correlation coefficient. A strong negative correlation (as signal
    // drops, latency rises) is evidence that WiFi is the root cause of latency
    // degradation — even if average signal looks borderline acceptable.

    private func checkWiFiLatencyCorrelation(_ input: SessionAnalysisInput,
                                              sufficiency: DataSufficiency) -> [NetworkFinding] {
        guard input.wifiRows.count >= 20,
              input.pingRows.count >= 20 else { return [] }

        // Build paired (RSSI, RTT) observations by matching each ping row to the
        // nearest WiFi sample within ±15 seconds.
        var pairs: [(rssi: Double, rtt: Double)] = []
        for pingRow in input.pingRows {
            guard let rtt = pingRow.rttMs else { continue }
            let t = pingRow.timestamp.timeIntervalSince1970
            // Binary-search-friendly: wifi rows are ascending by timestamp
            let nearest = input.wifiRows.min(by: {
                abs($0.timestamp.timeIntervalSince1970 - t) <
                abs($1.timestamp.timeIntervalSince1970 - t)
            })
            guard let wifi = nearest,
                  abs(wifi.timestamp.timeIntervalSince1970 - t) <= 15 else { continue }
            pairs.append((Double(wifi.rssi), rtt))
        }
        guard pairs.count >= 20 else { return [] }

        // Pearson r
        let n      = Double(pairs.count)
        let rssis  = pairs.map(\.rssi)
        let rtts   = pairs.map(\.rtt)
        let rssiM  = rssis.reduce(0, +) / n
        let rttM   = rtts.reduce(0, +) / n
        let num    = zip(rssis, rtts).map { ($0 - rssiM) * ($1 - rttM) }.reduce(0, +)
        let denR   = sqrt(rssis.map { pow($0 - rssiM, 2) }.reduce(0, +))
        let denL   = sqrt(rtts.map   { pow($0 - rttM,  2) }.reduce(0, +))
        guard denR > 0, denL > 0 else { return [] }
        let r = num / (denR * denL)

        // Only surface strong negative correlations (RSSI drops → RTT rises)
        guard r < -0.45 else { return [] }

        let strength: String
        let base: Double
        switch r {
        case ..<(-0.75): strength = "strong"; base = 0.85
        case ..<(-0.60): strength = "moderate"; base = 0.70
        default:         strength = "mild"; base = 0.55
        }

        let wifiSufficiency = DataSufficiency(sampleCount: pairs.count)
        let confidence = min(1.0, base * wifiSufficiency.multiplier)

        let detail = String(format: "There is a %@ negative correlation (r = %.2f) between Wi-Fi signal strength and latency for this session. As signal dropped, round-trip times rose correspondingly — consistent with Wi-Fi being the primary cause of latency degradation rather than ISP or server-side issues.",
                            strength, r)

        return [NetworkFinding(category: .wifi,
                               title: "Wi-Fi signal correlates with latency",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 8: Per-target divergence
    //
    // Compares per-target average RTT and loss against the session-wide average.
    // When one target consistently shows significantly worse metrics than the
    // others, the problem is likely specific to that destination (CDN, routing
    // path, geographic distance) rather than the local connection or ISP.

    private func checkTargetDivergence(_ input: SessionAnalysisInput,
                                        sufficiency: DataSufficiency) -> [NetworkFinding] {
        guard input.pingRowsByTarget.count >= 2 else { return [] }

        // Compute per-target average RTT and loss
        struct TargetStats {
            let id: UUID; let avgRTT: Double?; let avgLoss: Double; let count: Int
        }
        var stats: [TargetStats] = []
        for (id, rows) in input.pingRowsByTarget {
            guard rows.count >= 10 else { continue }
            let rtts = rows.compactMap(\.rttMs)
            let avgRTT  = rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count)
            let avgLoss = rows.map(\.lossPct).reduce(0, +) / Double(rows.count)
            stats.append(TargetStats(id: id, avgRTT: avgRTT, avgLoss: avgLoss, count: rows.count))
        }
        guard stats.count >= 2 else { return [] }

        // Overall average RTT across all valid targets
        let allRTTs    = stats.compactMap(\.avgRTT)
        guard !allRTTs.isEmpty else { return [] }
        let overallAvg = allRTTs.reduce(0, +) / Double(allRTTs.count)
        guard overallAvg > 0 else { return [] }

        var findings: [NetworkFinding] = []

        for s in stats {
            guard let tAvg = s.avgRTT else { continue }
            let ratio = tAvg / overallAvg

            // Flag if this target is more than 2.5x the overall average
            guard ratio > 2.5 else { continue }

            let label = pingTargetLabels[s.id]
                     ?? s.id.uuidString.prefix(8).description

            let base: Double = ratio > 4.0 ? 0.80 : 0.65
            let targetSufficiency = DataSufficiency(sampleCount: s.count)
            let confidence = min(1.0, base * targetSufficiency.multiplier)

            let detail = String(format: "\"%@\" averaged %.0f ms RTT — %.1f× higher than the %.0f ms average across other targets. This pattern suggests a routing, geographic, or CDN issue specific to that destination rather than a problem with the local network or ISP.",
                                label, tAvg, ratio, overallAvg)

            findings.append(NetworkFinding(category: .latency,
                                           title: "Outlier target: \(label)",
                                           detail: detail,
                                           confidence: confidence))
        }

        return findings
    }

    // MARK: - Pattern 11: Network interface errors
    //
    // Delta counters from `netstat -i` are sampled every ~30 s. Each row stores the
    // change in cumulative errors_in, errors_out, and drops_in since the prior sample.
    // On modern WiFi, hardware-level errors reaching the software interface are rare
    // and indicate RF interference, driver problems, or hardware faults.

    private func checkInterfaceErrors(_ input: SessionAnalysisInput,
                                       sufficiency: DataSufficiency) -> [NetworkFinding] {
        // Need at least 3 samples to distinguish a persistent pattern from transient noise
        guard input.interfaceErrorRows.count >= 3 else { return [] }

        let nonZeroRows = input.interfaceErrorRows.filter {
            $0.errorsIn + $0.errorsOut + $0.dropsIn > 0
        }
        // Require at least 2 separate intervals with errors to avoid flagging one-off glitches
        guard nonZeroRows.count >= 2 else { return [] }

        let totalErrors = input.interfaceErrorRows.reduce(0) { $0 + $1.errorsIn + $1.errorsOut }
        let totalDrops  = input.interfaceErrorRows.reduce(0) { $0 + $1.dropsIn }
        let iface       = input.interfaceErrorRows.first?.iface ?? "unknown"

        let base: Double = nonZeroRows.count >= 5 ? 0.75 : 0.55
        let confidence   = min(1.0, base * sufficiency.multiplier)

        let detail = String(format: "Interface %@ recorded %d input/output error(s) and %d drop(s) across %d of %d sampling intervals. Hardware-level errors are rare on modern hardware; when persistent, they indicate RF interference, a failing network adapter, or driver buffer overflows — not congestion or a routing issue.",
                            iface, Int(totalErrors), Int(totalDrops),
                            nonZeroRows.count, input.interfaceErrorRows.count)

        return [NetworkFinding(category: .connectivity,
                               title: "Network interface errors detected",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 10: DNS resolution latency / failures
    //
    // Samples are taken every ~30 s via DNSMonitor.measure(). A resolveMs of nil means
    // the resolution failed outright. Two independent findings can fire: slow average
    // resolution time (≥ 200 ms) and elevated failure rate (≥ 10 %).

    private func checkDNS(_ input: SessionAnalysisInput,
                           sufficiency: DataSufficiency) -> [NetworkFinding] {
        guard input.dnsRows.count >= 5 else { return [] }

        let total    = input.dnsRows.count
        let resolved = input.dnsRows.compactMap(\.resolveMs)
        let failCount = total - resolved.count
        let failRate  = Double(failCount) / Double(total)

        // Scale sufficiency on DNS sample count (1 sample ≈ 30 s, so 12 ≈ adequate)
        let dnsSuf = DataSufficiency(sampleCount: total * 12)

        var findings: [NetworkFinding] = []

        // Finding A — high failure rate
        if failRate >= 0.10 {
            let base: Double = failRate >= 0.30 ? 0.85 : 0.65
            let confidence   = min(1.0, base * dnsSuf.multiplier)
            let detail = String(format: "%.0f%% of DNS lookups failed (%d of %d samples). DNS failures prevent hostname resolution and can cause intermittent connectivity errors even when the network path is otherwise healthy. Check router DNS settings or try switching to a public resolver such as 1.1.1.1 or 8.8.8.8.",
                                failRate * 100, failCount, total)
            findings.append(NetworkFinding(category: .connectivity,
                                           title: "DNS resolution failures",
                                           detail: detail,
                                           confidence: confidence))
        }

        // Finding B — slow average resolution
        if !resolved.isEmpty {
            let avg = resolved.reduce(0, +) / Double(resolved.count)
            if avg >= 200 {
                let base: Double = avg >= 500 ? 0.80 : 0.60
                let confidence   = min(1.0, base * dnsSuf.multiplier)
                let detail = String(format: "DNS resolution averaged %.0f ms (threshold 200 ms). Slow DNS adds hidden latency to every new connection — websites and apps feel sluggish even when server ping times are low. The likely cause is a slow router DNS relay or ISP resolver; switching to 1.1.1.1 or 8.8.8.8 typically resolves it.",
                                    avg)
                findings.append(NetworkFinding(category: .connectivity,
                                               title: "Slow DNS resolution",
                                               detail: detail,
                                               confidence: confidence))
            }
        }

        return findings
    }

    // MARK: - Patterns 10a–10e: Multi-resolver DNS analysis

    /// Main entry point for multi-resolver DNS patterns. Skipped when no resolver data exists.
    private func checkDNSMultiResolver(_ input: SessionAnalysisInput) -> [NetworkFinding] {
        guard !input.dnsResolverRows.isEmpty else { return [] }

        // Group rows by resolver IP
        var byIP: [String: [SQLiteStore.DNSResolverRow]] = [:]
        for row in input.dnsResolverRows {
            byIP[row.resolverIP, default: []].append(row)
        }

        var findings: [NetworkFinding] = []
        findings += checkDNSFailureRate(byIP)
        findings += checkDNSLatency(byIP)
        findings += checkDNSResolverComparison(byIP)
        findings += checkDNSAllFailing(byIP, pingRows: input.pingRows)
        findings += checkDNSPortBlocking(byIP)
        return findings
    }

    /// Pattern 10a — Per-resolver failure rate.
    /// Fires when a specific resolver has > 15% failure rate.
    private func checkDNSFailureRate(_ byIP: [String: [SQLiteStore.DNSResolverRow]]) -> [NetworkFinding] {
        var findings: [NetworkFinding] = []
        for (_, rows) in byIP {
            guard rows.count >= 5 else { continue }
            let name      = rows.first?.resolverName ?? rows.first?.resolverIP ?? "Unknown"
            let ip        = rows.first?.resolverIP ?? ""
            let failures  = rows.filter { $0.resolveMs == nil && $0.rcode != 3 }  // timeout/SERVFAIL, not NXDOMAIN
            let failRate  = Double(failures.count) / Double(rows.count)
            guard failRate >= 0.15 else { continue }

            let suf        = DataSufficiency(sampleCount: rows.count * 12)
            let base: Double = failRate >= 0.40 ? 0.85 : 0.65
            let confidence = min(1.0, base * suf.multiplier)

            let detail = String(format: "\"%@\" (%@) failed %.0f%% of the time (%d of %d probes). Consider disabling this resolver if failures persist, or check for connectivity issues specific to this server.",
                                name, ip, failRate * 100, failures.count, rows.count)
            findings.append(NetworkFinding(category: .connectivity,
                                           title: "DNS resolver \"\(name)\" unreliable",
                                           detail: detail,
                                           confidence: confidence))
        }
        return findings
    }

    /// Pattern 10b — DNS latency (trimmed mean of best resolver).
    /// Fires when even the best-performing resolver exceeds 200 ms average.
    private func checkDNSLatency(_ byIP: [String: [SQLiteStore.DNSResolverRow]]) -> [NetworkFinding] {
        // Find the fastest resolver by trimmed mean
        var bestName  = ""
        var bestRTT   = Double.infinity
        var systemIP  = ""
        var gatewayIP = ""

        for (ip, rows) in byIP {
            guard rows.count >= 5 else { continue }
            let rtts = rows.compactMap(\.resolveMs)
            guard let mean = trimmedMeanDNS(rtts) else { continue }
            if mean < bestRTT {
                bestRTT  = mean
                bestName = rows.first?.resolverName ?? ip
            }
            if rows.first?.resolverName.lowercased().contains("system") == true { systemIP = ip }
            if rows.first?.resolverName.lowercased().contains("gateway") == true
               || rows.first?.resolverName.lowercased().contains("router") == true { gatewayIP = ip }
        }

        guard bestRTT < .infinity, bestRTT >= 200 else { return [] }

        func avgRTT(_ rows: [SQLiteStore.DNSResolverRow]?) -> Double? {
            guard let rows, !rows.isEmpty else { return nil }
            let rtts = rows.compactMap(\.resolveMs)
            guard !rtts.isEmpty else { return nil }
            return rtts.reduce(0, +) / Double(rtts.count)
        }
        let systemRTT  = avgRTT(byIP[systemIP])
        let gatewayRTT = avgRTT(byIP[gatewayIP])

        // Determine if system/gateway resolver is specifically responsible
        var recommendation = "Consider switching to a faster public resolver."
        if let sRTT = systemRTT, sRTT >= 300, bestRTT < sRTT * 0.5 {
            recommendation = "Public resolvers are significantly faster than your system resolver. Configuring a faster resolver in your router settings could noticeably speed up browsing."
        } else if let gRTT = gatewayRTT, gRTT >= 300, bestRTT < gRTT * 0.5 {
            recommendation = "Your router DNS relay is slow. Configuring a faster resolver like Cloudflare (1.1.1.1) in your router settings could help."
        }

        let suf        = DataSufficiency(sampleCount: byIP.values.first?.count.advanced(by: 0) ?? 0)
        let base: Double = bestRTT >= 500 ? 0.80 : 0.60
        let confidence = min(1.0, base * suf.multiplier)

        let detail = String(format: "Even the fastest resolver (\"%@\") averaged %.0f ms — above the 200 ms threshold. Slow DNS adds hidden latency to every new connection. %@",
                            bestName, bestRTT, recommendation)
        return [NetworkFinding(category: .connectivity,
                               title: "Slow DNS resolution",
                               detail: detail,
                               confidence: confidence)]
    }

    /// Pattern 10c — Resolver performance comparison.
    /// Fires when the fastest public resolver is 2× faster than system/gateway resolver.
    private func checkDNSResolverComparison(_ byIP: [String: [SQLiteStore.DNSResolverRow]]) -> [NetworkFinding] {
        var publicResolvers:   [(name: String, rtt: Double)] = []
        var systemGatewayRTT: Double?
        var systemGatewayName = "your system resolver"

        for (_, rows) in byIP where rows.count >= 10 {
            let rtts = rows.compactMap(\.resolveMs)
            guard let mean = trimmedMeanDNS(rtts) else { continue }
            let name = rows.first?.resolverName ?? ""
            let isLocal = name.lowercased().contains("system")
                       || name.lowercased().contains("gateway")
                       || name.lowercased().contains("router")
            if isLocal {
                if systemGatewayRTT == nil || mean < systemGatewayRTT! {
                    systemGatewayRTT  = mean
                    systemGatewayName = name
                }
            } else {
                publicResolvers.append((name: name, rtt: mean))
            }
        }

        guard let sysRTT = systemGatewayRTT,
              let fastest = publicResolvers.min(by: { $0.rtt < $1.rtt }),
              sysRTT > 0, fastest.rtt > 0,
              sysRTT / fastest.rtt >= 2.0 else { return [] }

        let detail = String(format: "\"%@\" averages %.0f ms. \"%@\" averages %.0f ms — %.1f× faster. Configuring \"%@\" as your primary resolver in your router settings could noticeably speed up browsing and app load times.",
                            systemGatewayName, sysRTT,
                            fastest.name, fastest.rtt,
                            sysRTT / fastest.rtt,
                            fastest.name)
        return [NetworkFinding(category: .connectivity,
                               title: "Faster DNS resolver available",
                               detail: detail,
                               confidence: 0.65)]
    }

    /// Pattern 10d — All resolvers failing simultaneously.
    /// When all resolvers fail, it indicates a network outage — not a DNS fault.
    private func checkDNSAllFailing(_ byIP: [String: [SQLiteStore.DNSResolverRow]],
                                     pingRows: [SQLiteStore.PingRow]) -> [NetworkFinding] {
        guard byIP.count >= 3 else { return [] }  // need enough resolvers to be meaningful
        let resolversWithData = byIP.filter { $0.value.count >= 5 }
        guard resolversWithData.count >= 3 else { return [] }

        // Check failure rate per resolver — all must be > 80%
        let allFailing = resolversWithData.allSatisfy { _, rows in
            let failures = rows.filter { $0.resolveMs == nil }
            return Double(failures.count) / Double(rows.count) > 0.80
        }
        guard allFailing else { return [] }

        // Cross-reference with packet loss to confirm network-level cause
        let loss = pingRows.map(\.lossPct).reduce(0, +) / Double(max(pingRows.count, 1))
        let crossRef = loss > 20
            ? " This is consistent with the packet loss also detected in this session."
            : ""

        let detail = "All DNS resolvers (\(resolversWithData.count) monitored) were unreachable for most of this session. When all resolvers fail simultaneously, the cause is typically a complete network outage or severe connectivity degradation rather than a DNS-specific issue.\(crossRef)"
        return [NetworkFinding(category: .connectivity,
                               title: "Complete DNS failure — likely network outage",
                               detail: detail,
                               confidence: 0.80)]
    }

    /// Pattern 10e — External resolver blocking (UDP port 53 blocked).
    /// Fires when external public resolvers consistently fail while system/gateway succeeds.
    private func checkDNSPortBlocking(_ byIP: [String: [SQLiteStore.DNSResolverRow]]) -> [NetworkFinding] {
        var externalFailRates: [Double] = []
        var localFailRates:    [Double] = []

        for (_, rows) in byIP where rows.count >= 5 {
            let name    = rows.first?.resolverName ?? ""
            let isLocal = name.lowercased().contains("system")
                       || name.lowercased().contains("gateway")
                       || name.lowercased().contains("router")
            let failRate = Double(rows.filter { $0.resolveMs == nil }.count) / Double(rows.count)
            if isLocal { localFailRates.append(failRate) }
            else       { externalFailRates.append(failRate) }
        }

        guard !externalFailRates.isEmpty, !localFailRates.isEmpty else { return [] }

        let avgExternalFail = externalFailRates.reduce(0, +) / Double(externalFailRates.count)
        let avgLocalFail    = localFailRates.reduce(0, +) / Double(localFailRates.count)

        // External resolvers consistently failing while local resolver is healthy
        guard avgExternalFail >= 0.70, avgLocalFail <= 0.20 else { return [] }

        let detail = "Public DNS resolvers were unreachable on this network (%.0f%% failure rate) while your local/gateway resolver worked normally (%.0f%% failure rate). This pattern indicates that UDP port 53 is blocked for external destinations — common on enterprise, hotel, and some ISP networks. Only your network's configured resolver is usable here."

        return [NetworkFinding(category: .connectivity,
                               title: "External DNS blocked (UDP/53 filtered)",
                               detail: String(format: detail, avgExternalFail * 100, avgLocalFail * 100),
                               confidence: 0.80)]
    }

    /// Trimmed mean for DNS latency: drop bottom/top 10% (min 1) when ≥ 4 samples.
    private func trimmedMeanDNS(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        guard values.count >= 4 else { return values.reduce(0, +) / Double(values.count) }
        let sorted    = values.sorted()
        let trimCount = max(1, values.count / 10)
        let trimmed   = sorted.dropFirst(trimCount).dropLast(trimCount)
        guard !trimmed.isEmpty else { return sorted[sorted.count / 2] }
        return trimmed.reduce(0, +) / Double(trimmed.count)
    }

    // MARK: - Pattern 9: Bufferbloat detection
    //
    // Compares idle baseline RTT (from ping samples) against the under-load
    // latency recorded by the speed test. A large ratio indicates bufferbloat —
    // oversized router or modem buffers that inflate latency under throughput load.

    private func checkBufferbloat(_ input: SessionAnalysisInput,
                                   sufficiency: DataSufficiency) -> [NetworkFinding] {
        guard !input.speedtestRows.isEmpty else { return [] }

        let rtts = input.pingRows.compactMap(\.rttMs)
        guard rtts.count >= 10 else { return [] }

        let baselineRTT  = rtts.reduce(0, +) / Double(rtts.count)
        // Skip: if idle latency is already bad, bufferbloat isn't the primary diagnosis
        guard baselineRTT < thresholds.latencyYellowMs else { return [] }
        guard baselineRTT > 0 else { return [] }

        let underLoadRTTs = input.speedtestRows.map(\.latencyMs)
        let underLoadAvg  = underLoadRTTs.reduce(0, +) / Double(underLoadRTTs.count)

        let ratio = underLoadAvg / baselineRTT
        // Only flag when latency at least doubles under load
        guard ratio >= 2.0 else { return [] }

        let severity: String
        let base: Double
        switch ratio {
        case 4.0...: severity = "severe"; base = 0.85
        case 3.0...: severity = "significant"; base = 0.75
        default:     severity = "moderate"; base = 0.60
        }

        // Speedtest sufficiency: scale count so 5 tests ≈ adequate
        let speedSufficiency = DataSufficiency(sampleCount: input.speedtestRows.count * 24)
        let confidence = min(1.0, base * speedSufficiency.multiplier)

        let detail = String(format: "Idle latency averaged %.0f ms, but during speed tests it rose to %.0f ms (%.1f× higher). This %@ increase under load is a classic sign of bufferbloat — large buffers in a router or modem queue packets and inflate latency when the connection is saturated. Enabling SQM/FQ-CoDel on your router, if supported, typically resolves this.",
                            baselineRTT, underLoadAvg, ratio, severity)

        return [NetworkFinding(category: .bandwidth,
                               title: "Bufferbloat detected",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 12: MTU / path fragmentation
    //
    // MTUChecker probes with a 1472-byte payload (1500-byte Ethernet frame) with the
    // Don't-Fragment bit set.  If the probe fails while normal pings succeed, something
    // on the path is blocking or fragmenting large packets — common with misconfigured
    // VPNs, PPPoE links without correct MSS clamping, or strict middleboxes.

    private func checkMTU(_ input: SessionAnalysisInput,
                           sufficiency: DataSufficiency) -> [NetworkFinding] {
        guard input.mtuRows.count >= 2 else { return [] }

        let failedProbes = input.mtuRows.filter { !$0.reachable }
        let failRate = Double(failedProbes.count) / Double(input.mtuRows.count)
        // Only flag if the majority of probes fail (≥ 50%) to avoid spurious single-packet loss
        guard failRate >= 0.50 else { return [] }

        let host         = input.mtuRows.first?.host ?? "unknown"
        let payloadBytes = input.mtuRows.first?.payloadBytes ?? MTUChecker.standardPayload

        // Scale confidence by how many probes confirm the pattern
        let base: Double = input.mtuRows.count >= 5 ? 0.80 : 0.60
        let confidence   = min(1.0, base * sufficiency.multiplier)

        let detail = String(format: "%d of %d large-packet probes to %@ failed (%.0f%% loss). The probe uses a %d-byte payload with the Don't-Fragment bit set, producing a standard 1500-byte Ethernet frame. This pattern typically indicates that something on the network path — a VPN tunnel, PPPoE DSL link, or strict firewall — is blocking or fragmenting oversized packets. Small pings may still succeed while web pages load slowly or stall (\"PMTUD black hole\"). Correcting MSS clamping or raising the MTU on intervening devices usually resolves this.",
                            failedProbes.count, input.mtuRows.count, host,
                            failRate * 100, payloadBytes)

        return [NetworkFinding(category: .connectivity,
                               title: "Possible MTU / path fragmentation issue",
                               detail: detail,
                               confidence: confidence)]
    }
}
