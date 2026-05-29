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
        case latency       = "Latency"
        case packetLoss    = "Packet Loss"
        case jitter        = "Jitter"
        case wifi          = "Wi-Fi Signal"
        case bandwidth     = "Bandwidth"
        case connectivity  = "Connectivity"
        case dns           = "DNS"
        case configuration = "Configuration"
    }

    let id = UUID()
    let category: Category
    let title: String
    let detail: String
    /// 0–1. Accounts for data sufficiency and session mixing.
    let confidence: Double
    /// Optional long-form text shown in a disclosure section (e.g. raw traceroute output).
    let expandedDetail: String?

    init(category: Category, title: String, detail: String,
         confidence: Double, expandedDetail: String? = nil) {
        self.category       = category
        self.title          = title
        self.detail         = detail
        self.confidence     = confidence
        self.expandedDetail = expandedDetail
    }

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
    /// Cross-session hourly average RTTs keyed by hour-of-day (0–23). Sourced from
    /// `ping_aggregates` across all historical sessions; used by the time-of-day pattern.
    var crossSessionHourlyRTTs: [Int: Double] = [:]
    /// Traceroute snapshots captured during detected degradation events for this session.
    var tracerouteRows: [SQLiteStore.TracerouteEventRow] = []
    /// Name of the VPN/tunnel interface active when this session was opened, or nil.
    /// Sourced from `network_sessions.vpn_interface`. When non-nil, the analyzer surfaces
    /// a high-confidence informational finding so users understand latency includes tunnel overhead.
    var vpnInterface: String? = nil
    /// Cross-session weekday average RTTs keyed by weekday (0 = Sunday … 6 = Saturday).
    /// Sourced from `ping_aggregates` across all historical sessions; used by pattern #17.
    var crossSessionWeekdayRTTs: [Int: Double] = [:]
    /// Median RTT learned from the first 30 minutes of this session.
    /// nil when the session is younger than 30 min or has fewer than 10 baseline samples.
    /// Used by checkLatency to reduce false positives on high-latency-but-stable connections
    /// (e.g. satellite or distant VPN) and to surface regressions above the learned normal.
    var learnedBaselineRTT: Double? = nil
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

        // VPN finding is factual — always surfaces regardless of data sufficiency.
        if let vpnFinding = checkVPN(input) { findings.append(vpnFinding) }

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
        findings += checkLatencyTrend(input, sufficiency: sufficiency)
        findings += checkChannelSwitching(input, sufficiency: sufficiency)
        findings += checkTimeOfDayPattern(input)
        findings += checkTraceroute(input)
        findings += checkWeekdayPattern(input)

        return findings.filter { $0.confidence >= 0.40 }
    }

    // MARK: - VPN informational finding

    /// Returns a high-confidence informational finding when a VPN tunnel was active at session open.
    /// Confidence 1.0 — this is a fact, not a probability — and it always surfaces.
    private func checkVPN(_ input: SessionAnalysisInput) -> NetworkFinding? {
        guard let iface = input.vpnInterface else { return nil }
        return NetworkFinding(
            category:   .configuration,
            title:      "VPN Active",
            detail:     "A VPN tunnel (\(iface)) was active during this session. " +
                        "Latency readings include tunnel overhead and do not reflect raw ISP performance.",
            confidence: 1.0
        )
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

        var base: Double = avg >= thresh * 2 ? 0.85 : 0.65
        var baselineNote: String? = nil

        // Per-network learned baseline: if this connection normally runs at high latency
        // (e.g. satellite, distant VPN), reduce confidence when avg is near the baseline.
        // If avg has significantly regressed above the baseline, note it and keep confidence.
        if let bl = input.learnedBaselineRTT, bl > 0 {
            if avg < bl * 1.30 {
                // Within 30% of the learned normal — likely not an anomaly, just how this
                // network behaves. Halve the confidence so it only surfaces when strong.
                base *= 0.5
                baselineNote = String(format: "This is typical for this network (baseline %.0f ms).", bl)
            } else if avg > bl * 1.50 {
                baselineNote = String(format: "RTT has regressed %.0f%% above this network's baseline (%.0f ms).",
                                      (avg / bl - 1) * 100, bl)
            }
        }

        let confidence = min(1.0, (base + confidenceBoost) * sufficiency.multiplier)
        guard confidence >= 0.40 else { return [] }

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
        if let note = baselineNote {
            detail += " " + note
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
        // Pre-extract timestamps once so the binary search only touches a Double array.
        let wifiTimestamps = input.wifiRows.map { $0.timestamp.timeIntervalSince1970 }

        var pairs: [(rssi: Double, rtt: Double)] = []
        for pingRow in input.pingRows {
            guard let rtt = pingRow.rttMs else { continue }
            let t = pingRow.timestamp.timeIntervalSince1970

            // Binary search for the insertion point of t in the sorted wifiTimestamps array.
            var lo = 0, hi = wifiTimestamps.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if wifiTimestamps[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            // Check the two candidates around the insertion point and pick the closer one.
            var bestIdx: Int? = nil
            var bestDist = Double.infinity
            for idx in [lo - 1, lo] where idx >= 0 && idx < wifiTimestamps.count {
                let d = abs(wifiTimestamps[idx] - t)
                if d < bestDist { bestDist = d; bestIdx = idx }
            }
            guard let idx = bestIdx, bestDist <= 15 else { continue }
            pairs.append((Double(input.wifiRows[idx].rssi), rtt))
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
            findings.append(NetworkFinding(category: .dns,
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
                findings.append(NetworkFinding(category: .dns,
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
            findings.append(NetworkFinding(category: .dns,
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
        return [NetworkFinding(category: .dns,
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
        return [NetworkFinding(category: .dns,
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
        return [NetworkFinding(category: .dns,
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

        return [NetworkFinding(category: .dns,
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

    // MARK: - Pattern 13: Latency trend (linear regression)

    private func checkLatencyTrend(_ input: SessionAnalysisInput,
                                    sufficiency: DataSufficiency) -> [NetworkFinding] {
        let sorted = input.pingRows.sorted { $0.timestamp < $1.timestamp }
        guard let origin = sorted.first else { return [] }

        let pairs: [(x: Double, y: Double)] = sorted.compactMap { r in
            guard let rtt = r.rttMs else { return nil }
            return (r.timestamp.timeIntervalSince(origin.timestamp), rtt)
        }
        guard pairs.count >= 20 else { return [] }

        // Ordinary least-squares regression: y = intercept + slope * x
        let n     = Double(pairs.count)
        let sumX  = pairs.reduce(0) { $0 + $1.x }
        let sumY  = pairs.reduce(0) { $0 + $1.y }
        let sumXY = pairs.reduce(0) { $0 + $1.x * $1.y }
        let sumX2 = pairs.reduce(0) { $0 + $1.x * $1.x }
        let denom = n * sumX2 - sumX * sumX
        guard abs(denom) > 0 else { return [] }

        let slope     = (n * sumXY - sumX * sumY) / denom   // ms per second
        let intercept = (sumY - slope * sumX) / n
        let slopePerMin = slope * 60.0

        // Only surface meaningful upward trends (degradation over time)
        guard slopePerMin > 0.30 else { return [] }

        // R² measures how well the linear fit explains the variance; low R² means
        // the "trend" is just noise.
        let yMean     = sumY / n
        let totalSS   = pairs.reduce(0) { $0 + pow($1.y - yMean, 2) }
        let residualSS = pairs.reduce(0) { acc, p in
            acc + pow(p.y - (intercept + slope * p.x), 2)
        }
        let r2 = totalSS > 0 ? max(0, 1.0 - residualSS / totalSS) : 0.0
        guard r2 >= 0.20 else { return [] }

        let sessionHours = (pairs.last?.x ?? 0) / 3600.0
        let base: Double = slopePerMin >= 1.0 ? 0.80 : (slopePerMin >= 0.5 ? 0.65 : 0.50)
        let confidence   = min(1.0, base * sufficiency.multiplier)

        let detail = String(
            format: "Latency increased steadily at %.1f ms per minute over %.1f hours " +
                    "(R² = %.2f, indicating a %@ fit). This pattern can indicate " +
                    "progressive router buffer saturation, thermal throttling on a " +
                    "network device, or an application steadily increasing background " +
                    "traffic throughout the session.",
            slopePerMin, sessionHours, r2,
            r2 >= 0.5 ? "strong linear" : "moderate")

        return [NetworkFinding(category: .latency,
                               title: "Latency trending upward",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 14: Time-of-day congestion pattern (cross-session)

    /// Uses cross-session hourly averages fetched from `ping_aggregates` to detect
    /// recurring peak-hour congestion patterns across all historical sessions.
    func checkTimeOfDayPattern(_ input: SessionAnalysisInput) -> [NetworkFinding] {
        guard !input.crossSessionHourlyRTTs.isEmpty else { return [] }

        let thresh = thresholds.latencyYellowMs
        let overall = input.crossSessionHourlyRTTs.values.reduce(0, +)
                      / Double(input.crossSessionHourlyRTTs.count)
        guard overall > 0 else { return [] }

        // Find hours where the average is > 1.5× overall average AND exceeds the
        // latency threshold — hours that look bad relative to the user's baseline.
        let peakHours = input.crossSessionHourlyRTTs
            .filter { $0.value >= thresh && $0.value >= overall * 1.5 }
            .sorted { $0.key < $1.key }

        guard !peakHours.isEmpty else { return [] }

        // Require at least 2 peak hours or one severely elevated hour
        let severe = peakHours.filter { $0.value >= thresh * 2 }
        guard peakHours.count >= 2 || !severe.isEmpty else { return [] }

        // Confidence scales with how many hours show the pattern
        let base: Double = peakHours.count >= 4 ? 0.75 : (peakHours.count >= 2 ? 0.65 : 0.55)
        // No sufficiency multiplier — this uses historical aggregate data, not just
        // the current session's sample count.
        let confidence = base

        let hourStrs = peakHours.map { (h, avg) in
            String(format: "%02d:00 (avg %.0f ms)", h, avg)
        }.joined(separator: ", ")

        let detail = "Historical data shows recurring elevated latency during: \(hourStrs). " +
            "This pattern typically indicates time-of-day congestion — either on your ISP's " +
            "network during peak usage hours or on a shared local link (apartment building, " +
            "campus, or cable segment). Consider scheduling large downloads outside these windows."

        return [NetworkFinding(category: .latency,
                               title: "Recurring peak-hour congestion",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 15: Traceroute snapshot during degradation

    /// Surfaces traceroute snapshots captured automatically when the connection degraded.
    func checkTraceroute(_ input: SessionAnalysisInput) -> [NetworkFinding] {
        guard !input.tracerouteRows.isEmpty else { return [] }

        var findings: [NetworkFinding] = []
        for row in input.tracerouteRows.prefix(3) {  // at most 3 snapshots per session
            let summary = parseTracerouteSummary(row.output)
            let timeStr = {
                let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
                return f.string(from: row.timestamp)
            }()

            let contextStr: String
            if let rtt = row.triggerRTTMs, let loss = row.triggerLossPct {
                contextStr = String(format: "Triggered at %@ when RTT was %.0f ms and loss %.1f%%.",
                                    timeStr, rtt, loss)
            } else {
                contextStr = "Captured at \(timeStr) during a detected degradation event."
            }

            let detail = "\(contextStr) \(summary)"

            findings.append(NetworkFinding(category: .connectivity,
                                           title: "Traceroute snapshot",
                                           detail: detail,
                                           confidence: 0.60,
                                           expandedDetail: row.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        // Baseline comparison — when ≥2 snapshots exist, diff the first (baseline) against
        // the most recent to surface re-routes or per-hop latency regressions.
        if input.tracerouteRows.count >= 2,
           let baseline = input.tracerouteRows.first,
           let latest = input.tracerouteRows.last,
           let diff = compareTraceroutes(baseline: baseline.output, current: latest.output) {
            findings.append(NetworkFinding(
                category: .connectivity,
                title: "Route change detected",
                detail: diff,
                confidence: 0.70,
                expandedDetail: nil
            ))
        }

        return findings
    }

    /// Parses `/usr/sbin/traceroute` output and returns a plain-English summary
    /// highlighting the hop count and the highest-latency hop.
    private func parseTracerouteSummary(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Traceroute output lines look like: " 3  192.168.1.1  1.234 ms  ..."
        // or " 3  * * *" for timeouts
        var hopCount = 0
        var maxRTT: Double = 0
        var maxHop = 0

        for line in lines.dropFirst() {  // first line is the header
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let hopNum = parts.first.flatMap({ Int(String($0)) }) else { continue }
            hopCount = hopNum
            // Find the first ms value on the line
            for (i, part) in parts.enumerated() {
                if part == "ms", i > 0, let rtt = Double(String(parts[i - 1])), rtt > maxRTT {
                    maxRTT = rtt
                    maxHop = hopNum
                }
            }
        }

        if hopCount == 0 { return "Traceroute did not complete (all hops timed out)." }
        if maxRTT > 0 {
            return String(format: "Route reached %d hops. Highest latency at hop %d (%.0f ms). " +
                          "High RTT at an early hop (1–3) points to the local network; " +
                          "high RTT at a later hop points to ISP or internet routing.",
                          hopCount, maxHop, maxRTT)
        }
        return "Route completed in \(hopCount) hops (all hops timed out — router may block ICMP TTL-exceeded messages)."
    }

    /// Parse traceroute output into a list of hops: (hop number, IP or "*", RTT in ms or nil).
    private func parseHops(_ output: String) -> [(hop: Int, ip: String, rttMs: Double?)] {
        var result: [(hop: Int, ip: String, rttMs: Double?)] = []
        for line in output.components(separatedBy: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // Require at least a hop-number column and an IP/wildcard column.
            guard parts.count >= 2, let hopNum = Int(String(parts[0])) else { continue }
            let ipPart = String(parts[1])
            if ipPart == "*" {
                result.append((hopNum, "*", nil))
                continue
            }
            // Find the first RTT: a numeric token immediately followed by "ms".
            // Both parts[i] and parts[i-1] are within bounds because i starts at 1 and
            // the loop upper bound is parts.count, so i-1 >= 0 and i < parts.count.
            var rtt: Double? = nil
            for i in 1..<parts.count {
                if parts[i] == "ms", let v = Double(String(parts[i - 1])) {
                    rtt = v; break
                }
            }
            result.append((hopNum, ipPart, rtt))
        }
        return result
    }

    /// Compares two traceroute outputs and returns a plain-English diff summary, or nil if no
    /// meaningful differences are found.
    private func compareTraceroutes(baseline: String, current: String) -> String? {
        let baseHops = parseHops(baseline)
        let currHops = parseHops(current)
        guard !baseHops.isEmpty && !currHops.isEmpty else { return nil }

        var changes: [String] = []

        // Hop count change
        if baseHops.count != currHops.count {
            changes.append("Hop count changed from \(baseHops.count) to \(currHops.count).")
        }

        // Per-hop comparison (by hop number)
        let baseByHop = Dictionary(uniqueKeysWithValues: baseHops.map { ($0.hop, $0) })
        let currByHop = Dictionary(uniqueKeysWithValues: currHops.map { ($0.hop, $0) })

        let sharedHops = Set(baseByHop.keys).intersection(Set(currByHop.keys)).sorted()
        for hop in sharedHops {
            guard let b = baseByHop[hop], let c = currByHop[hop] else { continue }

            // IP changed (ignore * hops)
            if b.ip != "*" && c.ip != "*" && b.ip != c.ip {
                changes.append("Hop \(hop) changed from \(b.ip) → \(c.ip) (possible re-route).")
            }

            // RTT degraded significantly (≥50% increase and absolute increase ≥20ms)
            if let bRTT = b.rttMs, let cRTT = c.rttMs,
               cRTT > bRTT * 1.5, cRTT - bRTT >= 20 {
                changes.append(String(format: "Hop %d RTT increased %.0f ms → %.0f ms (+%.0f%%)",
                                      hop, bRTT, cRTT, (cRTT / bRTT - 1) * 100))
            }
        }

        guard !changes.isEmpty else { return nil }
        return "vs. earlier snapshot — " + changes.prefix(3).joined(separator: " ")
    }

    // MARK: - Pattern 16: Wi-Fi channel / band switching

    private func checkChannelSwitching(_ input: SessionAnalysisInput,
                                        sufficiency: DataSufficiency) -> [NetworkFinding] {
        let sorted = input.wifiRows.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 3 else { return [] }

        var channelChanges = 0
        var bandChanges    = 0
        var channelSeq: [Int] = sorted.first.map { [$0.channelNumber] } ?? []

        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            // Skip gaps > 10 minutes — these represent session interruptions, not live switches
            guard curr.timestamp.timeIntervalSince(prev.timestamp) < 600 else { continue }
            if curr.channelNumber != prev.channelNumber {
                channelChanges += 1
                if channelSeq.last != curr.channelNumber { channelSeq.append(curr.channelNumber) }
            }
            if abs(curr.bandGHz - prev.bandGHz) > 0.5 {
                bandChanges += 1
            }
        }

        guard channelChanges >= 2 else { return [] }

        let seqStr = channelSeq.map { String($0) }.joined(separator: " → ")
        let base: Double = bandChanges > 0 ? 0.75 : (channelChanges >= 4 ? 0.70 : 0.60)
        let confidence   = min(1.0, base * sufficiency.multiplier)

        var detail = "Wi-Fi channel changed \(channelChanges) time(s) during this session " +
            "(channel sequence: \(seqStr))."
        if bandChanges > 0 {
            detail += " The device also switched frequency band (2.4 GHz ↔ 5 GHz) " +
                "\(bandChanges) time(s), which forces a full re-association and can cause " +
                "brief connectivity interruptions."
        }
        detail += " Frequent channel changes suggest RF interference causing the access " +
            "point to self-heal, the device roaming between access points, or DFS " +
            "(Dynamic Frequency Selection) events on 5 GHz channels."

        return [NetworkFinding(category: .wifi,
                               title: "Wi-Fi channel switching detected",
                               detail: detail,
                               confidence: confidence)]
    }

    // MARK: - Pattern 17: Recurring weekly pattern

    func checkWeekdayPattern(_ input: SessionAnalysisInput) -> [NetworkFinding] {
        let weekdayRTTs = input.crossSessionWeekdayRTTs
        guard weekdayRTTs.count >= 4 else { return [] }

        let values  = Array(weekdayRTTs.values)
        let mean    = values.reduce(0, +) / Double(values.count)
        guard mean > 0 else { return [] }
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        let stddev   = variance.squareRoot()

        // Find weekdays with average > mean + 1.5 * stddev AND delta > 10 ms
        let threshold = mean + 1.5 * stddev
        let elevated  = weekdayRTTs.filter { $0.value > threshold && ($0.value - mean) > 10 }
        guard !elevated.isEmpty else { return [] }

        // Confidence scales with how many weekdays have data and how elevated the worst day is
        let maxDelta  = elevated.values.map { $0 - mean }.max() ?? 0
        let base: Double = weekdayRTTs.count >= 6 ? 0.70 : (weekdayRTTs.count >= 5 ? 0.60 : 0.55)
        let severityBonus: Double = maxDelta > 30 ? 0.05 : 0
        let confidence = min(0.90, base + severityBonus)

        let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let dayStr = elevated
            .sorted { $0.value > $1.value }
            .map { (wd, avg) in
                let name = wd < dayNames.count ? dayNames[wd] : "Day \(wd)"
                return String(format: "%@ (avg %.0f ms)", name, avg)
            }
            .joined(separator: ", ")

        let detail = String(format:
            "Average latency is consistently elevated on %@, compared to a weekly average of " +
            "%.0f ms. This pattern may reflect ISP congestion, scheduled maintenance, or " +
            "increased neighbourhood usage on that day.", dayStr, mean)

        return [NetworkFinding(category: .latency,
                               title: "Recurring weekly pattern",
                               detail: detail,
                               confidence: confidence)]
    }
}
