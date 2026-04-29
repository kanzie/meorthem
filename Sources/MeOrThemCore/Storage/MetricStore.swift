import Foundation
import Combine

// 6h at 5s poll = 4,320 samples per target — enough for export/reports
private let kPingHistoryCapacity = 4_320
// 1h of WiFi snapshots (changes rarely — RSSI, channel, SSID)
private let kWifiHistoryCapacity = 720

@MainActor
public final class MetricStore: ObservableObject {

    // MARK: - Published snapshots (drive icon + menu updates)
    @Published public private(set) var latestPing: [UUID: PingResult] = [:]
    @Published public private(set) var latestWifi: WiFiSnapshot?
    @Published public private(set) var overallStatus: MetricStatus = .green
    @Published public private(set) var networkFaultType: NetworkFaultType = .none

    // MARK: - VPN state (set by AppEnvironment on session open and ~once per minute)
    @Published public private(set) var vpnInterface: String? = nil

    public func recordVPNInterface(_ name: String?) { vpnInterface = name }

    // MARK: - Gateway ping (set by MonitoringEngine each tick)
    public private(set) var latestGatewayPing: PingResult?
    @Published public private(set) var latestGatewayIP: String?

    // MARK: - Sleep/wake context (set by AppEnvironment on wake events)
    /// Timestamp of the last system wake event. Used to annotate post-wake incidents.
    public var lastWakeDate: Date? = nil

    // MARK: - Availability (uptime percentage, updated hourly by AppEnvironment)
    @Published public private(set) var availability24h: Double? = nil
    @Published public private(set) var availability7d:  Double? = nil
    @Published public private(set) var availability30d: Double? = nil

    public func recordAvailability(h24: Double?, d7: Double?, d30: Double?) {
        availability24h = h24
        availability7d  = d7
        availability30d = d30
    }

    // MARK: - Current network session (set by AppEnvironment on WiFi fingerprint change)
    public var currentSessionID: UUID?
    /// ISP/ASN name for the current session, resolved asynchronously at session open. nil until resolved.
    @Published public private(set) var currentSessionISPName: String? = nil

    public func recordSessionISP(_ name: String?) { currentSessionISPName = name }

    /// Whether a captive portal was detected on the current session's network.
    /// nil = probe not yet complete or inconclusive; true = portal; false = clear.
    @Published public private(set) var captivePortalDetected: Bool? = nil

    public func recordCaptivePortal(_ detected: Bool?) { captivePortalDetected = detected }

    /// Whether DNS answer divergence (possible hijacking) was detected on the current session.
    /// true = at least one resolver returned a private IP or answers disagreed across resolvers.
    @Published public private(set) var dnsHijackSuspected: Bool = false

    public func recordDNSHijackSuspicion(_ suspected: Bool) { dnsHijackSuspected = suspected }

    // MARK: - History (read by export + sparklines)
    public private(set) var pingHistory: [UUID: CircularBuffer<PingResult>] = [:]
    public private(set) var wifiHistory: CircularBuffer<WiFiSnapshot> = CircularBuffer(capacity: kWifiHistoryCapacity)
    private var statusHistory: CircularBuffer<MetricStatus> = CircularBuffer(capacity: 5)

    // MARK: - DNS resolver summary (drives menu tag 6; no SQLite reads)

    public struct DNSSummary {
        /// Name of the fastest-responding enabled resolver this window.
        public let bestResolverName: String
        /// Trimmed-mean RTT of the best resolver's last 10 samples (ms).
        public let bestRTTMs: Double
        /// Fraction of last-10 samples that timed out across all enabled resolvers.
        public let failRate: Double
        /// Count of enabled resolvers that responded this window.
        public let respondingCount: Int
        /// Total enabled resolver count.
        public let totalCount: Int
        /// Derived status colour.
        public let status: MetricStatus
    }

    /// Most-recently computed DNS summary. nil until the first probe round completes.
    @Published public private(set) var dnsSummary: DNSSummary?

    /// Rolling 10-sample RTT buffer per resolver IP (nil entries = timeout/failure).
    private var dnsRollingBuffer: [String: [Double?]] = [:]

    // MARK: - Connection history (last 20 degradation events, backed by SQLite)
    @Published public private(set) var connectionHistory: [ConnectionEvent] = []
    private var previousOverallStatus: MetricStatus = .green
    // In-memory cap for menu display; SQLite retains full history per incidentRetentionDays.
    private static let kMaxConnectionEvents = 20
    private static let kHistoryUDKey = "metricStore.connectionHistory"

    // MARK: - Settings reference for threshold evaluation
    private let settings: AppSettings
    private let sqliteStore: SQLiteStore?

    /// Called on every successful ping record — used by LogExporter for append-mode CSV.
    public var onPingRecorded: ((PingResult, UUID) -> Void)?
    /// Called on every WiFi snapshot — used by LogExporter for append-mode CSV.
    public var onWiFiRecorded: ((WiFiSnapshot) -> Void)?

    public init(settings: AppSettings, sqliteStore: SQLiteStore? = nil) {
        self.settings = settings
        self.sqliteStore = sqliteStore
        loadConnectionHistory()
    }

    // MARK: - Write methods (called from MonitoringEngine)

    public func record(result: PingResult, for targetID: UUID) {
        latestPing[targetID] = result
        if pingHistory[targetID] == nil {
            pingHistory[targetID] = CircularBuffer(capacity: kPingHistoryCapacity)
        }
        pingHistory[targetID]!.append(result)
        recomputeOverallStatus()

        // Notify observers (e.g. LogExporter for append-mode CSV).
        onPingRecorded?(result, targetID)

        // Persist to SQLite — look up label/host from settings or fall back to the ID string.
        if let db = sqliteStore {
            let target = settings.pingTargets.first(where: { $0.id == targetID })
            let label  = target?.label ?? (targetID == PingTarget.gatewayID ? "Gateway" : targetID.uuidString)
            let host   = target?.host  ?? ""
            db.insertPing(timestamp:   result.timestamp,
                          rtt:         result.rtt,
                          lossPercent: result.lossPercent,
                          jitter:      result.jitter,
                          targetID:    targetID,
                          targetLabel: label,
                          host:        host,
                          sessionID:   currentSessionID)
        }
    }

    public func recordWiFi(_ snapshot: WiFiSnapshot?) {
        latestWifi = snapshot
        if let s = snapshot {
            wifiHistory.append(s)
            onWiFiRecorded?(s)
            sqliteStore?.insertWiFi(timestamp:     s.timestamp,
                                    rssi:          s.rssi,
                                    noise:         s.noise,
                                    snr:           s.snr,
                                    channel:       s.channelNumber,
                                    bandGHz:       s.channelBandGHz,
                                    txRateMbps:    s.txRateMbps,
                                    phyMode:       s.phyMode,
                                    interfaceName: s.interfaceName,
                                    ipAddress:     s.ipAddress,
                                    routerIP:      s.routerIP,
                                    sessionID:     currentSessionID)
        }
    }

    /// Persists a single interface error delta sample for the current session.
    /// All values are deltas (change since the previous sample), clamped to ≥ 0.
    public func recordInterfaceDelta(errorsIn: Int64, errorsOut: Int64, dropsIn: Int64, iface: String) {
        sqliteStore?.insertInterfaceErrors(timestamp: Date(),
                                           iface: iface,
                                           errorsIn: errorsIn,
                                           errorsOut: errorsOut,
                                           dropsIn: dropsIn,
                                           sessionID: currentSessionID)
    }

    /// Persists a DNS resolution sample for the current session.
    public func recordDNS(resolveMs: Double?, hostname: String) {
        sqliteStore?.insertDNS(timestamp: Date(),
                               hostname: hostname,
                               resolveMs: resolveMs,
                               sessionID: currentSessionID)
    }

    /// Persists an MTU probe result for the current session.
    public func recordMTUResult(host: String, payloadBytes: Int, reachable: Bool, rttMs: Double?) {
        sqliteStore?.insertMTUCheck(timestamp: Date(),
                                    host: host,
                                    payloadBytes: payloadBytes,
                                    reachable: reachable,
                                    rttMs: rttMs,
                                    sessionID: currentSessionID)
    }

    /// Record one resolver probe result. Updates the rolling buffer + summary and
    /// persists to SQLite. Call from MonitoringEngine after each probe round.
    public func recordDNSResolverSample(resolver: DNSResolver, resolveMs: Double?, rcode: Int?) {
        // Update rolling 10-sample buffer.
        let ip = resolver.ip.isEmpty ? resolver.name : resolver.ip
        var buf = dnsRollingBuffer[ip] ?? []
        buf.append(resolveMs)
        if buf.count > 10 { buf.removeFirst(buf.count - 10) }
        dnsRollingBuffer[ip] = buf

        // Persist to SQLite.
        sqliteStore?.insertDNSResolverSample(
            timestamp:    Date(),
            resolverIP:   ip,
            resolverName: resolver.name,
            queryHost:    "example.com",
            resolveMs:    resolveMs,
            rcode:        rcode,
            sessionID:    currentSessionID)
    }

    /// Recompute `dnsSummary` from the current rolling buffers.
    /// Call after the full probe round (all resolver results recorded).
    public func refreshDNSSummary(enabledResolvers: [(name: String, ip: String)]) {
        guard !enabledResolvers.isEmpty else { dnsSummary = nil; return }

        var bestName  = ""
        var bestRTT   = Double.infinity
        var totalFail = 0
        var totalSamples = 0
        var respondingCount = 0

        for r in enabledResolvers {
            let key = r.ip.isEmpty ? r.name : r.ip
            let buf = dnsRollingBuffer[key] ?? []
            guard !buf.isEmpty else { continue }

            let successes = buf.compactMap { $0 }
            let failures  = buf.count - successes.count
            totalFail    += failures
            totalSamples += buf.count
            if !successes.isEmpty { respondingCount += 1 }

            if let mean = trimmedMeanDNS(successes), mean < bestRTT {
                bestRTT  = mean
                bestName = r.name
            }
        }

        let failRate: Double = totalSamples > 0 ? Double(totalFail) / Double(totalSamples) : 0

        // Derive colour thresholds per design:
        // Green:  avg < 80 ms AND 0% failure
        // Yellow: avg 80–200 ms OR 0–30% failure
        // Red:    avg > 200 ms OR > 30% failure OR all resolvers timing out
        let status: MetricStatus
        if bestRTT == .infinity || failRate > 0.30 {
            status = .red
        } else if bestRTT > 200 || failRate > 0 || bestRTT > 80 {
            status = .yellow
        } else {
            status = .green
        }

        dnsSummary = DNSSummary(
            bestResolverName: bestName.isEmpty ? "DNS" : bestName,
            bestRTTMs:        bestRTT == .infinity ? 0 : bestRTT,
            failRate:         failRate,
            respondingCount:  respondingCount,
            totalCount:       enabledResolvers.count,
            status:           status)
    }

    /// Trimmed mean for DNS RTT samples: drop bottom and top 10% (min 1 each) when ≥4 samples.
    private func trimmedMeanDNS(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        guard values.count >= 4 else {
            return values.reduce(0, +) / Double(values.count)
        }
        let sorted     = values.sorted()
        let trimCount  = max(1, values.count / 10)
        let trimmed    = sorted.dropFirst(trimCount).dropLast(trimCount)
        guard !trimmed.isEmpty else { return sorted[sorted.count / 2] }
        return trimmed.reduce(0, +) / Double(trimmed.count)
    }

    public func recordGatewayPing(_ result: PingResult?, gatewayIP: String? = nil) {
        if let ip = gatewayIP { latestGatewayIP = ip }
        latestGatewayPing = result
        recomputeFaultType()
    }

    // MARK: - System load

    /// Most-recent sampled CPU utilisation fraction (0–1). Updated each tick before pings run.
    @Published public private(set) var currentSystemLoad: Double = 0
    private var recentSystemLoads = CircularBuffer<Double>(capacity: 3)   // ~15 s at 5 s poll

    /// Called by MonitoringEngine at the start of every tick with the delta CPU fraction.
    public func recordSystemLoad(_ fraction: Double) {
        currentSystemLoad = fraction
        recentSystemLoads.append(fraction)
    }

    private var averageRecentSystemLoad: Double {
        let all = recentSystemLoads.last(recentSystemLoads.count)
        guard !all.isEmpty else { return 0 }
        return all.reduce(0, +) / Double(all.count)
    }

    // MARK: - Derived

    /// Returns the window-averaged status for a target.
    public func effectiveStatus(for targetID: UUID) -> MetricStatus {
        windowedStatus(for: targetID)
    }

    public func latencyHistory(for targetID: UUID, last n: Int = 60) -> [Double] {
        pingHistory[targetID]?.last(n).compactMap(\.rtt) ?? []
    }

    public func lossHistory(for targetID: UUID, last n: Int = 60) -> [Double] {
        pingHistory[targetID]?.last(n).map(\.lossPercent) ?? []
    }

    /// Sparkline data: last N RTT values for a target (nil = timeout replaced by 0 for display).
    public func sparklineData(for targetID: UUID, last n: Int = 12) -> [Double] {
        pingHistory[targetID]?.last(n).map { $0.rtt ?? 0 } ?? []
    }

    /// Returns the last N overall status values in chronological order (oldest first).
    public func recentOverallStatuses(last n: Int = 5) -> [MetricStatus] {
        statusHistory.last(n)
    }

    // MARK: - Private

    /// Returns the window-averaged status for a target.
    /// Uses per-target threshold override when set, otherwise falls back to global thresholds.
    /// Each metric is averaged over its configured evaluation window, expressed as
    /// sample count = ceil(windowSecs / pollIntervalSecs). This naturally filters
    /// brief single-poll spikes (AWDL, roaming) without needing a separate debounce.
    private func windowedStatus(for targetID: UUID) -> MetricStatus {
        guard let history = pingHistory[targetID] else { return .red }
        let t    = settings.pingTargets.first(where: { $0.id == targetID })?.thresholdOverride
                   ?? settings.thresholds
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
        // Compute per-target windowed statuses for fault-type isolation logic.
        var effectiveStatuses = [UUID: MetricStatus](minimumCapacity: latestPing.count)
        for targetID in latestPing.keys {
            guard targetID != PingTarget.gatewayID else { continue }
            effectiveStatuses[targetID] = windowedStatus(for: targetID)
        }

        // Targets with per-target threshold overrides are evaluated individually;
        // their status feeds directly into the worst-case without participating in the
        // trimmed mean (overrides are intentional, not outliers to be discarded).
        // Targets without overrides use the global trimmed-mean approach.
        let overrideTargetIDs = Set(settings.pingTargets
            .filter { $0.thresholdOverride != nil }
            .map(\.id))

        let overrideWorst: MetricStatus = effectiveStatuses
            .filter { overrideTargetIDs.contains($0.key) }
            .values
            .max() ?? .green

        let globalWorst = trimmedMeanStatus(excluding: overrideTargetIDs)
        let worst = max(overrideWorst, globalWorst)

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
        // Close any previously-open event both in memory and in SQLite.
        if let idx = connectionHistory.firstIndex(where: { $0.isActive }) {
            let prev = connectionHistory[idx]
            let closeTime = Date()
            connectionHistory[idx].endTime = closeTime
            sqliteStore?.closeIncident(id: prev.id, endTime: closeTime,
                                       peakSeverityRaw: prev.severityRaw)
        }
        let event = ConnectionEvent(severity: severity, cause: cause)
        connectionHistory.insert(event, at: 0)
        if connectionHistory.count > Self.kMaxConnectionEvents { connectionHistory.removeLast() }
        saveConnectionHistory()
        sqliteStore?.openIncident(id: event.id, severityRaw: severity.rawValue,
                                  cause: cause, startTime: event.startTime)
    }

    private func closeActiveConnectionEvent() {
        guard let idx = connectionHistory.firstIndex(where: { $0.isActive }) else { return }
        let event = connectionHistory[idx]
        connectionHistory[idx].endTime = Date()
        saveConnectionHistory()
        sqliteStore?.closeIncident(id: event.id, endTime: Date(),
                                   peakSeverityRaw: event.severityRaw)
    }

    private func updateActiveEventSeverity(_ newSeverity: MetricStatus) {
        guard let idx = connectionHistory.firstIndex(where: { $0.isActive }),
              newSeverity.rawValue > connectionHistory[idx].severityRaw else { return }
        let e = connectionHistory[idx]
        connectionHistory[idx] = ConnectionEvent(severity: newSeverity, startTime: e.startTime, cause: e.cause)
        saveConnectionHistory()
        sqliteStore?.updateIncidentSeverity(id: e.id, peakSeverityRaw: newSeverity.rawValue)
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
        // Annotate with system load if CPU was high when degradation started.
        let avgCPU = averageRecentSystemLoad
        if avgCPU >= 0.75 {
            parts.append(String(format: "high system load (%.0f%%)", avgCPU * 100))
        }

        var cause = parts.isEmpty ? "network degradation" : parts.joined(separator: ", ")
        // Tag incidents that begin within 90 seconds of a system wake event.
        if let wake = lastWakeDate, Date().timeIntervalSince(wake) <= 90 {
            cause += " (post-wake)"
        }
        return cause
    }

    public func clearConnectionHistory() {
        connectionHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.kHistoryUDKey)
        sqliteStore?.clearAllIncidents()
    }

    private static let _historyEncoder = JSONEncoder()

    /// Write-through to UserDefaults as a fast-load cache; SQLite is the authoritative store.
    private func saveConnectionHistory() {
        if let data = try? Self._historyEncoder.encode(Array(connectionHistory.prefix(Self.kMaxConnectionEvents))) {
            UserDefaults.standard.set(data, forKey: Self.kHistoryUDKey)
        }
    }

    /// Load on launch: prefer SQLite (full fidelity); fall back to UserDefaults cache.
    private func loadConnectionHistory() {
        if let db = sqliteStore {
            // Close every open incident from previous sessions in a single pass.
            // This covers all rows in the table, not just the most-recent batch.
            db.closeAllOpenIncidents()
            let rows = db.recentIncidents(limit: Self.kMaxConnectionEvents)
            connectionHistory = rows.map { row in
                var event = ConnectionEvent(id: row.id,
                                            severityRaw: row.peakSeverityRaw,
                                            startTime: row.startedAt,
                                            cause: row.cause,
                                            endTime: row.endedAt ?? Date())
                // endedAt should already be set by closeAllOpenIncidents above, but
                // clamp any that arrived after the batch update (race window is negligible).
                if event.isActive { event.endTime = Date() }
                return event
            }
            return
        }
        // No SQLite available — fall back to UserDefaults cache
        guard let data = UserDefaults.standard.data(forKey: Self.kHistoryUDKey),
              let events = try? JSONDecoder().decode([ConnectionEvent].self, from: data)
        else { return }
        connectionHistory = events
        if let idx = connectionHistory.firstIndex(where: { $0.isActive }) {
            connectionHistory[idx].endTime = Date()
        }
    }

    // MARK: - Trimmed mean across targets

    /// Returns the window-averaged raw metric values for a single target.
    private func windowedMetricAverages(for targetID: UUID) -> (avgLoss: Double, avgLatency: Double?, avgJitter: Double?) {
        guard let history = pingHistory[targetID] else { return (100, nil, nil) }
        let poll     = settings.pollIntervalSecs
        let latencyN = max(1, Int(ceil(settings.latencyWindowSecs / poll)))
        let lossN    = max(1, Int(ceil(settings.lossWindowSecs    / poll)))
        let jitterN  = max(1, Int(ceil(settings.jitterWindowSecs  / poll)))
        let samples  = history.last(max(latencyN, max(lossN, jitterN)))

        let lossSlice    = Array(samples.suffix(lossN)).map(\.lossPercent)
        let latencySlice = Array(samples.suffix(latencyN)).compactMap(\.rtt)
        let jitterSlice  = Array(samples.suffix(jitterN)).compactMap(\.jitter)

        let avgLoss    = lossSlice.isEmpty    ? 100.0 : lossSlice.reduce(0, +)    / Double(lossSlice.count)
        let avgLatency = latencySlice.isEmpty ? nil   : latencySlice.reduce(0, +) / Double(latencySlice.count)
        let avgJitter  = jitterSlice.isEmpty  ? nil   : jitterSlice.reduce(0, +)  / Double(jitterSlice.count)
        return (avgLoss, avgLatency, avgJitter)
    }

    /// Computes overall status using a trimmed mean of metric averages across all non-gateway targets.
    private func trimmedMeanStatus(excluding: Set<UUID> = []) -> MetricStatus {
        let ids = latestPing.keys.filter { $0 != PingTarget.gatewayID && !excluding.contains($0) }
        guard !ids.isEmpty else { return .green }

        var losses:    [Double] = []
        var latencies: [Double] = []
        var jitters:   [Double] = []

        for id in ids {
            let m = windowedMetricAverages(for: id)
            losses.append(m.avgLoss)
            if let l = m.avgLatency { latencies.append(l) }
            if let j = m.avgJitter  { jitters.append(j) }
        }

        return MetricStatus.forWindow(
            loss:    [trimmedMean(losses)],
            latency: latencies.isEmpty ? [] : [trimmedMean(latencies)],
            jitter:  jitters.isEmpty   ? [] : [trimmedMean(jitters)],
            thresholds: settings.thresholds
        )
    }

    /// If ≥3 values, removes the single minimum and maximum before averaging.
    /// With 1–2 values, returns a plain average.
    private func trimmedMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        guard values.count >= 3 else { return values.reduce(0, +) / Double(values.count) }
        var sorted = values.sorted()
        sorted.removeFirst()
        sorted.removeLast()
        return sorted.reduce(0, +) / Double(sorted.count)
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

    public func summaryText(targets: [PingTarget]) -> String {
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
