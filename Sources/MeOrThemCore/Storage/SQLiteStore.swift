import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro; define the Swift equivalent here.
// It instructs SQLite to copy the bound value immediately, so the Swift
// string buffers can be released as soon as the bind call returns.
private let _SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Persistent SQLite store for all network metric data.
///
/// All database I/O is serialised on a private utility-priority queue so it
/// never touches the main thread. Public `insert*` methods are fire-and-forget
/// (queue.async). Public `query*` methods are synchronous (queue.sync) and
/// intended to be called from a background context (e.g. an export task).
///
/// The public API is primitive-based so it can be called from any module
/// without creating a dependency on internal Core domain types.
///
/// Data tiers managed automatically:
///   • `ping_samples`    — one row per poll per target; raw retention configurable (default 7 days)
///   • `wifi_samples`    — one row per WiFi snapshot; same raw retention
///   • `ping_aggregates` — per-minute roll-ups created from aged-out raw rows (default 366 days)
///   • `incidents`       — degradation event journal (default 1 year)
// Thread safety is managed entirely via `queue` — all mutable state (`db`) is only
// ever accessed on that serial queue. The @unchecked annotation opts out of the
// compiler's automatic Sendable checking, which cannot see through DispatchQueue.
public final class SQLiteStore: @unchecked Sendable {

    // MARK: - Public factory

    public static func makeDefault() -> SQLiteStore {
        SQLiteStore(path: Self.defaultDBPath)
    }

    public static var defaultDBPath: String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeOrThem", isDirectory: true)
        return dir.appendingPathComponent("metrics.db").path
    }

    // MARK: - Init / deinit

    public let path: String

    public init(path: String) {
        self.path = path
        queue.sync {
            self._open()
            self._createSchema()
            self._runMigrations()
        }
    }

    deinit {
        queue.sync {
            if self.db != nil { sqlite3_close_v2(self.db) }
        }
    }

    // MARK: - Private state (only ever accessed on `queue`)

    private let queue = DispatchQueue(label: "com.meorthem.sqlite", qos: .utility)
    private var db: OpaquePointer?

    // MARK: - Public insert API (primitive-based, fire-and-forget)

    public func insertPing(timestamp: Date,
                           rtt: Double?,
                           lossPercent: Double,
                           jitter: Double?,
                           targetID: UUID,
                           targetLabel: String,
                           host: String,
                           sessionID: UUID? = nil) {
        let ts      = timestamp.timeIntervalSince1970
        let idStr   = targetID.uuidString
        let sessStr = sessionID?.uuidString
        queue.async { [weak self] in
            self?._insertPing(ts: ts, targetID: idStr, label: targetLabel,
                              host: host, rtt: rtt, loss: lossPercent, jitter: jitter,
                              sessionID: sessStr)
        }
    }

    public func insertSpeedtest(timestamp: Date,
                               downloadMbps: Double,
                               uploadMbps: Double,
                               latencyMs: Double,
                               jitterMs: Double,
                               isp: String,
                               serverName: String) {
        let ts = timestamp.timeIntervalSince1970
        queue.async { [weak self] in
            self?._insertSpeedtest(ts: ts, dl: downloadMbps, ul: uploadMbps,
                                   lat: latencyMs, jit: jitterMs, isp: isp, server: serverName)
        }
    }

    public func insertDNS(timestamp: Date,
                          hostname: String,
                          resolveMs: Double?,
                          sessionID: UUID? = nil) {
        let ts      = timestamp.timeIntervalSince1970
        let sessStr = sessionID?.uuidString
        queue.async { [weak self] in
            self?._insertDNS(ts: ts, hostname: hostname, resolveMs: resolveMs, sessionID: sessStr)
        }
    }

    public func insertInterfaceErrors(timestamp: Date,
                                       iface: String,
                                       errorsIn: Int64,
                                       errorsOut: Int64,
                                       dropsIn: Int64,
                                       sessionID: UUID? = nil) {
        let ts      = timestamp.timeIntervalSince1970
        let sessStr = sessionID?.uuidString
        queue.async { [weak self] in
            self?._insertInterfaceErrors(ts: ts, iface: iface,
                                         errorsIn: errorsIn, errorsOut: errorsOut,
                                         dropsIn: dropsIn, sessionID: sessStr)
        }
    }

    public func insertMTUCheck(timestamp: Date,
                               host: String,
                               payloadBytes: Int,
                               reachable: Bool,
                               rttMs: Double?,
                               sessionID: UUID? = nil) {
        let ts      = timestamp.timeIntervalSince1970
        let sessStr = sessionID?.uuidString
        queue.async { [weak self] in
            self?._insertMTUCheck(ts: ts, host: host, payloadBytes: payloadBytes,
                                  reachable: reachable, rttMs: rttMs, sessionID: sessStr)
        }
    }

    /// MTU probe results for a specific session (ascending).
    public func mtuRows(sessionID: UUID) -> [MTURow] {
        queue.sync { _mtuRows(sessionID: sessionID.uuidString) }
    }

    /// Insert a single DNS resolver probe result. Fire-and-forget.
    public func insertDNSResolverSample(timestamp: Date,
                                        resolverIP: String,
                                        resolverName: String,
                                        queryHost: String,
                                        resolveMs: Double?,
                                        rcode: Int?,
                                        sessionID: UUID? = nil) {
        let ts      = timestamp.timeIntervalSince1970
        let sessStr = sessionID?.uuidString
        queue.async { [weak self] in
            self?._insertDNSResolverSample(ts: ts, resolverIP: resolverIP,
                                           resolverName: resolverName, queryHost: queryHost,
                                           resolveMs: resolveMs, rcode: rcode, sessionID: sessStr)
        }
    }

    /// All DNS resolver samples for a session, ascending by timestamp.
    public func dnsResolverRows(sessionID: UUID) -> [DNSResolverRow] {
        queue.sync { _dnsResolverRows(sessionID: sessionID.uuidString) }
    }

    /// All DNS resolver samples in a time range (for export and graphs), ascending.
    public func dnsResolverRows(from: Date, to: Date) -> [DNSResolverRow] {
        let lo = from.timeIntervalSince1970
        let hi = to.timeIntervalSince1970
        return queue.sync { _dnsResolverRowsInRange(from: lo, to: hi) }
    }

    // MARK: - Traceroute events

    /// Persists a traceroute output snapshot (fire-and-forget, serialised on the storage queue).
    public func insertTracerouteEvent(sessionID: UUID?,
                                      timestamp: Date,
                                      targetHost: String,
                                      output: String,
                                      hopCount: Int?,
                                      triggerRTTMs: Double?,
                                      triggerLossPct: Double?) {
        let ts  = timestamp.timeIntervalSince1970
        let sid = sessionID?.uuidString
        queue.async { [weak self] in
            self?._insertTracerouteEvent(sessionID: sid, timestamp: ts, targetHost: targetHost,
                                         output: output, hopCount: hopCount,
                                         triggerRTTMs: triggerRTTMs,
                                         triggerLossPct: triggerLossPct)
        }
    }

    /// All traceroute events for a session, ascending by timestamp.
    public func tracerouteEvents(sessionID: UUID) -> [TracerouteEventRow] {
        queue.sync { _tracerouteEvents(sessionID: sessionID.uuidString) }
    }

    // MARK: - Cross-session hourly RTT averages

    /// Computes per-hour-of-day (0–23) average RTT across all ping_aggregates in the
    /// lookback window. Used by the time-of-day congestion pattern in NetworkAnalyzer.
    /// Returns only hours that have at least `minSampleCount` aggregate rows.
    public func hourlyRTTAverages(lookback: TimeInterval,
                                   minSampleCount: Int = 3) -> [Int: Double] {
        let since = Date().addingTimeInterval(-lookback).timeIntervalSince1970
        return queue.sync { _hourlyRTTAverages(since: since, minSampleCount: minSampleCount) }
    }

    /// Computes per-weekday (0 = Sunday … 6 = Saturday) average RTT across all
    /// ping_aggregates in the lookback window. Returns only weekdays with at least
    /// `minSampleCount` aggregate rows. Used by the weekly-pattern chart and analyzer.
    public func weekdayRTTAverages(lookback: TimeInterval,
                                    minSampleCount: Int = 5) -> [Int: Double] {
        let since = Date().addingTimeInterval(-lookback).timeIntervalSince1970
        return queue.sync { _weekdayRTTAverages(since: since, minSampleCount: minSampleCount) }
    }

    public func insertWiFi(timestamp: Date,
                           rssi: Int,
                           noise: Int,
                           snr: Int,
                           channel: Int,
                           bandGHz: Double,
                           txRateMbps: Double,
                           phyMode: String,
                           interfaceName: String,
                           ipAddress: String?,
                           routerIP: String?,
                           sessionID: UUID? = nil) {
        let ts      = timestamp.timeIntervalSince1970
        let sessStr = sessionID?.uuidString
        queue.async { [weak self] in
            self?._insertWiFi(ts: ts, rssi: rssi, noise: noise, snr: snr,
                              channel: channel, bandGHz: bandGHz, txRate: txRateMbps,
                              phyMode: phyMode, iface: interfaceName,
                              ip: ipAddress, gw: routerIP, sessionID: sessStr)
        }
    }

    // MARK: - Public incident API (primitive-based, fire-and-forget)

    public func openIncident(id: UUID, severityRaw: Int, cause: String, startTime: Date = .init()) {
        let idStr = id.uuidString
        let ts    = startTime.timeIntervalSince1970
        queue.async { [weak self] in
            self?._openIncident(id: idStr, ts: ts, severity: severityRaw, cause: cause)
        }
    }

    public func closeIncident(id: UUID, endTime: Date = .init(), peakSeverityRaw: Int) {
        let idStr = id.uuidString
        let ts    = endTime.timeIntervalSince1970
        queue.async { [weak self] in
            self?._closeIncident(id: idStr, endTs: ts, peak: peakSeverityRaw)
        }
    }

    /// Close every incident that has no ended_at recorded (e.g. left open by a previous
    /// app session that was force-quit or crashed). Called once at launch.
    public func closeAllOpenIncidents(endTime: Date = .init()) {
        let ts = endTime.timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            let sql = "UPDATE incidents SET ended_at = ? WHERE ended_at IS NULL;"
            guard let stmt = _prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            sqlite3_step(stmt)
        }
    }

    public func updateIncidentSeverity(id: UUID, peakSeverityRaw: Int) {
        let idStr = id.uuidString
        queue.async { [weak self] in
            self?._updateIncidentSeverity(id: idStr, peak: peakSeverityRaw)
        }
    }

    /// Returns the raw ping rows surrounding an incident for diagnostic use.
    /// Fetches `preSeconds` of data before `startedAt` and `postSeconds` after `endedAt`
    /// (or after `startedAt` if the incident is still active).
    public func diagnosticPingRows(for targetID: UUID,
                                   incidentStart: Date,
                                   incidentEnd: Date?,
                                   preSeconds: Double = 300,
                                   postSeconds: Double = 300) -> [PingRow] {
        let from = incidentStart.addingTimeInterval(-preSeconds)
        let to   = (incidentEnd ?? incidentStart).addingTimeInterval(postSeconds)
        return pingRows(for: targetID, from: from, to: to)
    }

    /// Deletes all incident rows. Called when the user clears connection history.
    public func clearAllIncidents() {
        queue.async { [weak self] in
            self?._exec("DELETE FROM incidents;")
        }
    }

    /// Saves or clears the user-written note on a specific incident.
    /// Pass nil to remove an existing note.
    public func updateIncidentNote(id: UUID, note: String?) {
        let idStr = id.uuidString
        queue.async { [weak self] in
            guard let self else { return }
            let sql = "UPDATE incidents SET note = ? WHERE id = ?;"
            guard let stmt = self._prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            if let n = note, !n.isEmpty {
                self._bindText(stmt, 1, n)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            self._bindText(stmt, 2, idStr)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Maintenance (fire-and-forget)

    /// Aggregates raw samples older than `rawRetentionDays` into per-minute rows,
    /// then prunes all tiers according to their configured retention windows.
    /// Call on app launch and once per hour thereafter.
    public func aggregateAndPrune(rawRetentionDays: Int,
                                  aggregateRetentionDays: Int,
                                  incidentRetentionDays: Int) {
        let now        = Date().timeIntervalSince1970
        let rawCutoff  = now - Double(rawRetentionDays)       * 86_400
        let aggCutoff  = now - Double(aggregateRetentionDays) * 86_400
        let incCutoff  = now - Double(incidentRetentionDays)  * 86_400
        queue.async { [weak self] in
            self?._aggregate(before: rawCutoff)
            self?._execDeleteBefore(table: "ping_samples",        column: "timestamp",        cutoff: rawCutoff)
            self?._execDeleteBefore(table: "wifi_samples",        column: "timestamp",        cutoff: rawCutoff)
            self?._execDeleteBefore(table: "dns_samples",         column: "timestamp",        cutoff: rawCutoff)
            self?._execDeleteBefore(table: "interface_errors",    column: "timestamp",        cutoff: rawCutoff)
            self?._execDeleteBefore(table: "mtu_checks",          column: "timestamp",        cutoff: rawCutoff)
            self?._execDeleteBefore(table: "dns_resolver_samples",column: "timestamp",        cutoff: rawCutoff)
            self?._execDeleteBefore(table: "ping_aggregates",     column: "timestamp_minute", cutoff: aggCutoff)
            // Incidents: only prune rows that have already ended
            if let self {
                let sql = "DELETE FROM incidents WHERE ended_at IS NOT NULL AND ended_at < ?;"
                if let stmt = self._prepare(sql) {
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_double(stmt, 1, incCutoff)
                    sqlite3_step(stmt)
                }
            }
            self?._exec("PRAGMA wal_checkpoint(PASSIVE);")
        }
    }

    // MARK: - Public queries (synchronous; call from a background context for export)

    public struct PingRow {
        public let timestamp: Date
        public let targetID: UUID
        public let rttMs: Double?
        public let lossPct: Double
        public let jitterMs: Double?
    }

    public struct WiFiRow {
        public let timestamp: Date
        public let rssi: Int
        public let snr: Int
        public let channelNumber: Int
        public let bandGHz: Double
        public let txRateMbps: Double
    }

    public struct SpeedtestRow {
        public let timestamp:    Date
        public let downloadMbps: Double
        public let uploadMbps:   Double
        public let latencyMs:    Double
        public let jitterMs:     Double
        public let isp:          String
        public let serverName:   String
    }

    public struct DnsRow {
        public let timestamp: Date
        public let hostname: String
        /// Milliseconds to resolve, or `nil` when resolution failed.
        public let resolveMs: Double?
    }

    public struct InterfaceErrorRow {
        public let timestamp:  Date
        public let iface:      String
        /// Delta errors_in since the previous sample (clamped to ≥ 0).
        public let errorsIn:   Int64
        /// Delta errors_out since the previous sample.
        public let errorsOut:  Int64
        /// Delta input drops since the previous sample.
        public let dropsIn:    Int64
    }

    public struct MTURow {
        public let timestamp:    Date
        public let host:         String
        public let payloadBytes: Int
        /// `true` if the large-packet probe received a reply.
        public let reachable:    Bool
        /// Round-trip time in milliseconds if reachable.
        public let rttMs:        Double?
    }

    public struct DNSResolverRow {
        public let timestamp:    Date
        public let resolverIP:   String
        public let resolverName: String
        public let queryHost:    String
        /// Round-trip time in milliseconds. nil = timeout or SERVFAIL (check `rcode`).
        public let resolveMs:    Double?
        /// DNS RCODE: 0=NOERROR, 2=SERVFAIL, 3=NXDOMAIN. nil = socket timeout (no response).
        public let rcode:        Int?
    }

    public struct TracerouteEventRow {
        public let id:             Int64
        public let sessionID:      UUID?
        public let timestamp:      Date
        public let targetHost:     String
        /// Raw text output from `/usr/sbin/traceroute`.
        public let output:         String
        /// Number of hops to the final destination (nil if not reached).
        public let hopCount:       Int?
        /// The session's ambient RTT at the moment the traceroute was triggered.
        public let triggerRTTMs:   Double?
        /// The session's loss percentage at the moment of trigger.
        public let triggerLossPct: Double?
    }

    public struct NetworkSessionRow: Identifiable, Sendable {
        public let id:              UUID
        public let fingerprint:     String
        public let displayName:     String
        public let startedAt:       Date
        public let lastSeen:        Date
        /// Connection type string: "wifi", "ethernet", "vpn", or "unknown".
        /// Pre-migration rows default to "wifi".
        public let connectionType:  String
        /// True when the Ethernet fingerprint was created without a resolved gateway MAC.
        public let weakFingerprint: Bool
        /// Name of an active VPN/tunnel interface at the time the session was opened, e.g. "utun3".
        /// nil when no VPN was detected at session open time or for pre-migration rows.
        public let vpnInterface:    String?
        /// Autonomous System / ISP name resolved via DNS TXT lookup at session open time.
        /// nil when the lookup failed, timed out, or for pre-migration rows.
        public let ispName:         String?
        /// Median RTT computed from the first 30 minutes of the session.
        /// nil until 30 minutes of data have been collected and `computeAndStoreBaseline` called.
        public let learnedBaselineRTT: Double?
    }

    public struct IncidentRow: Identifiable {
        public let id: UUID
        public let startedAt: Date
        public let endedAt: Date?
        public let severityRaw: Int
        public let peakSeverityRaw: Int
        public let cause: String
        /// Optional free-text annotation added by the user (e.g. "ISP maintenance window").
        public let note: String?

        public var isActive: Bool { endedAt == nil }

        public init(id: UUID, startedAt: Date, endedAt: Date?, severityRaw: Int,
                    peakSeverityRaw: Int, cause: String, note: String? = nil) {
            self.id             = id
            self.startedAt      = startedAt
            self.endedAt        = endedAt
            self.severityRaw    = severityRaw
            self.peakSeverityRaw = peakSeverityRaw
            self.cause          = cause
            self.note           = note
        }
    }

    /// A system-level sleep or wake event recorded by the OS notification center.
    public struct SystemEventRow: Sendable {
        public let timestamp: Date
        public let eventType: String   // "sleep" | "wake"
    }

    /// Per-network-fingerprint profile storing stealth mode and ICMP health state.
    public struct ConnectionProfile: Identifiable, Sendable {
        public let fingerprint:           String
        public let displayName:           String
        /// User-assigned label for this network (e.g. "Home", "Office").
        /// When set, the UI uses this instead of the auto-generated displayName.
        public let userLabel:             String?
        public let stealthMode:           Bool
        public let stealthProbePort:      Int?
        public let stealthDetectedAt:     Date?
        public let stealthSource:         String?
        public let icmpLastOkAt:          Date?
        public let icmpThrottled:         Bool
        public let icmpThrottledAt:       Date?
        public let preferredPollInterval: Double?
        public let pollIntervalSource:    String?
        public let firstSeen:             Date
        public let lastSeen:              Date
        public let totalSessions:         Int

        public var id: String { fingerprint }
    }

    /// Raw ping samples in the given time range (ascending).
    public func pingRows(for targetID: UUID, from: Date, to: Date) -> [PingRow] {
        queue.sync { _pingRows(targetID: targetID.uuidString,
                               from: from.timeIntervalSince1970,
                               to:   to.timeIntervalSince1970) }
    }

    /// Per-minute aggregated ping rows in the given time range (ascending).
    public func aggregatedPingRows(for targetID: UUID, from: Date, to: Date) -> [PingRow] {
        queue.sync { _aggRows(targetID: targetID.uuidString,
                              from: from.timeIntervalSince1970,
                              to:   to.timeIntervalSince1970) }
    }

    /// WiFi samples in the given time range (ascending).
    public func wifiRows(from: Date, to: Date) -> [WiFiRow] {
        queue.sync { _wifiRows(from: from.timeIntervalSince1970,
                               to:   to.timeIntervalSince1970) }
    }

    /// Speedtest results in the given time range (ascending).
    public func speedtestRows(from: Date, to: Date) -> [SpeedtestRow] {
        queue.sync { _speedtestRows(from: from.timeIntervalSince1970,
                                    to:   to.timeIntervalSince1970) }
    }

    /// All persisted speedtest results (ascending).
    public func allSpeedtestRows() -> [SpeedtestRow] {
        queue.sync { _speedtestRows(from: 0, to: Date.distantFuture.timeIntervalSince1970) }
    }

    /// Opens (or re-uses) a network session record. Fire-and-forget.
    /// Default values for `connectionType` and `weakFingerprint` preserve backwards
    /// compatibility with all existing call sites.
    public func openSession(id: UUID,
                            fingerprint:     String,
                            displayName:     String,
                            connectionType:  String  = "wifi",
                            weakFingerprint: Bool    = false,
                            vpnInterface:    String? = nil,
                            startTime:       Date    = .init()) {
        let idStr   = id.uuidString
        let ts      = startTime.timeIntervalSince1970
        let weakInt = weakFingerprint ? 1 : 0
        queue.async { [weak self] in
            self?._openSession(id: idStr, fingerprint: fingerprint,
                               displayName: displayName, connectionType: connectionType,
                               weakFingerprint: weakInt, vpnInterface: vpnInterface, ts: ts)
        }
    }

    /// Updates the `isp_name` column for a session after an async ASN lookup completes.
    public func updateSessionISP(id: UUID, ispName: String) {
        let idStr = id.uuidString
        queue.async { [weak self] in
            self?._exec("UPDATE network_sessions SET isp_name = '\(ispName.replacingOccurrences(of: "'", with: "''"))' WHERE id = '\(idStr)';")
        }
    }

    /// Updates `last_seen` for the given session. Fire-and-forget.
    public func touchSession(id: UUID, at time: Date = .init()) {
        let idStr = id.uuidString
        let ts    = time.timeIntervalSince1970
        queue.async { [weak self] in
            self?._touchSession(id: idStr, ts: ts)
        }
    }

    /// Computes the median RTT from the first 30 minutes of the session and stores it
    /// in `network_sessions.baseline_rtt_ms`.  Requires at least 10 samples.
    /// Returns the computed median, or nil if there was insufficient data.
    /// Call from a background context — synchronous on the private queue.
    @discardableResult
    public func computeAndStoreBaseline(sessionID: UUID, from sessionStart: Date) -> Double? {
        let idStr  = sessionID.uuidString
        let fromTs = sessionStart.timeIntervalSince1970
        let toTs   = fromTs + 1_800  // 30 minutes

        return queue.sync {
            // Fetch RTTs from external targets (exclude gateway) within the first 30 min.
            let sql = """
                SELECT rtt_ms FROM ping_samples
                WHERE session_id = ? AND target_id != 'gateway'
                  AND timestamp >= ? AND timestamp <= ?
                  AND rtt_ms IS NOT NULL
                ORDER BY rtt_ms ASC;
                """
            guard let stmt = _prepare(sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            _bindText(stmt, 1, idStr)
            sqlite3_bind_double(stmt, 2, fromTs)
            sqlite3_bind_double(stmt, 3, toTs)
            var rtts: [Double] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rtts.append(sqlite3_column_double(stmt, 0))
            }
            guard rtts.count >= 10 else { return nil }
            // Already sorted ASC from the query.
            let mid    = rtts.count / 2
            let median = rtts.count % 2 == 0
                ? (rtts[mid - 1] + rtts[mid]) / 2
                : rtts[mid]
            _exec("UPDATE network_sessions SET baseline_rtt_ms = \(median) WHERE id = '\(idStr)';")
            return median
        }
    }

    /// Returns the most-recently-started session for the given fingerprint, if any.
    public func latestSession(for fingerprint: String) -> NetworkSessionRow? {
        queue.sync { _latestSession(fingerprint: fingerprint) }
    }

    /// Returns all sessions whose active window overlaps the given range.
    public func sessionsInRange(from: Date, to: Date) -> [NetworkSessionRow] {
        queue.sync { _sessionsInRange(from: from.timeIntervalSince1970,
                                      to:   to.timeIntervalSince1970) }
    }

    /// Raw ping samples for a specific session (ascending).
    public func pingRows(for targetID: UUID, sessionID: UUID) -> [PingRow] {
        queue.sync { _pingRows(targetID: targetID.uuidString,
                               sessionID: sessionID.uuidString) }
    }

    /// WiFi samples for a specific session (ascending).
    public func wifiRows(sessionID: UUID) -> [WiFiRow] {
        queue.sync { _wifiRows(sessionID: sessionID.uuidString) }
    }

    /// Interface error/drop delta rows for a specific session (ascending).
    public func interfaceErrorRows(sessionID: UUID) -> [InterfaceErrorRow] {
        queue.sync { _interfaceErrorRows(sessionID: sessionID.uuidString) }
    }

    /// DNS resolution samples for a specific session (ascending).
    public func dnsRows(sessionID: UUID) -> [DnsRow] {
        queue.sync { _dnsRows(sessionID: sessionID.uuidString) }
    }

    /// Most-recent incidents, newest first. Queries both open and resolved events.
    public func recentIncidents(limit: Int = 100) -> [IncidentRow] {
        queue.sync { _incidents(limit: limit) }
    }

    /// All incidents (open or resolved), newest first, up to `limit` rows.
    public func allIncidentRows(limit: Int = 500) -> [IncidentRow] {
        queue.sync { _incidents(limit: limit) }
    }

    /// Incidents whose started_at falls within [from, to], newest first.
    public func incidentRows(from: Date, to: Date, limit: Int = 500) -> [IncidentRow] {
        let f = from.timeIntervalSince1970
        let t = to.timeIntervalSince1970
        return queue.sync { _incidentsInRange(from: f, to: t, limit: limit) }
    }

    /// Returns the fraction of time [0.0–1.0] spent in a non-degraded state over the given window.
    /// 1.0 means 100% uptime. Returns nil when the window is empty or no incident data exists.
    ///
    /// Algorithm: fetch all closed incidents that overlap [from, to], merge overlapping intervals
    /// in Swift (sweep-line), sum degraded seconds, return 1 − (degraded / total).
    public func availabilityFraction(from: Date, to: Date) -> Double? {
        let fromTs = from.timeIntervalSince1970
        let toTs   = to.timeIntervalSince1970
        let total  = toTs - fromTs
        guard total > 0 else { return nil }

        // Fetch closed incidents that overlap the window.
        let rows: [(Double, Double)] = queue.sync {
            let sql = """
                SELECT started_at, ended_at FROM incidents
                WHERE ended_at IS NOT NULL
                  AND ended_at > ? AND started_at < ?
                ORDER BY started_at ASC;
                """
            guard let stmt = _prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, fromTs)
            sqlite3_bind_double(stmt, 2, toTs)
            var pairs: [(Double, Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let s = max(sqlite3_column_double(stmt, 0), fromTs)
                let e = min(sqlite3_column_double(stmt, 1), toTs)
                if e > s { pairs.append((s, e)) }
            }
            return pairs
        }

        guard !rows.isEmpty else { return nil }

        // Sweep-line merge of overlapping intervals to avoid double-counting.
        var merged: [(Double, Double)] = []
        var curStart = rows[0].0
        var curEnd   = rows[0].1
        for (s, e) in rows.dropFirst() {
            if s <= curEnd {
                curEnd = max(curEnd, e)
            } else {
                merged.append((curStart, curEnd))
                curStart = s
                curEnd   = e
            }
        }
        merged.append((curStart, curEnd))

        let degraded = merged.reduce(0.0) { $0 + ($1.1 - $1.0) }
        return max(0.0, 1.0 - (degraded / total))
    }

    /// Computes a `ConnectionStabilityScore` for the given session window.
    /// All I/O runs synchronously on the private queue — call from a background context.
    public func stabilityScore(from: Date, to: Date) -> ConnectionStabilityScore {
        let avail = availabilityFraction(from: from, to: to)

        // Aggregate mean RTT, loss and jitter from ping_samples in the window.
        let fromTs = from.timeIntervalSince1970
        let toTs   = to.timeIntervalSince1970

        let (meanRTT, meanLoss, meanJitter): (Double?, Double?, Double?) = queue.sync {
            let sql = """
                SELECT AVG(rtt_ms),
                       100.0 * SUM(CASE WHEN rtt_ms IS NULL THEN 1 ELSE 0 END) / COUNT(*),
                       AVG(jitter_ms)
                FROM ping_samples
                WHERE target_id != 'gateway'
                  AND timestamp >= ? AND timestamp <= ?;
                """
            guard let stmt = _prepare(sql) else { return (nil, nil, nil) }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, fromTs)
            sqlite3_bind_double(stmt, 2, toTs)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (nil, nil, nil) }
            // COUNT(*) check — if 0 rows matched, AVG returns NULL
            let rtt    = sqlite3_column_type(stmt, 0) != SQLITE_NULL ? sqlite3_column_double(stmt, 0) : nil as Double?
            let loss   = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? sqlite3_column_double(stmt, 1) : nil as Double?
            let jitter = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? sqlite3_column_double(stmt, 2) : nil as Double?
            // Require at least 5 samples for latency/loss to be meaningful
            let countSql = "SELECT COUNT(*) FROM ping_samples WHERE target_id != 'gateway' AND timestamp >= \(fromTs) AND timestamp <= \(toTs);"
            let n = _scalar(countSql)
            if n < 5 { return (nil, nil, nil) }
            return (rtt, loss, jitter)
        }

        return .compute(availability:  avail,
                        meanRTTMs:     meanRTT,
                        meanLossPct:   meanLoss,
                        meanJitterMs:  meanJitter)
    }

    /// Returns true if any ping data (raw or aggregated) exists in the given time range.
    /// Uses a LIMIT 1 query so it short-circuits immediately on the first matching row.
    public func hasPingData(from: Date, to: Date) -> Bool {
        let f = from.timeIntervalSince1970
        let t = to.timeIntervalSince1970
        return queue.sync {
            _scalarRange(table: "ping_samples",    column: "timestamp",        from: f, to: t) > 0
         || _scalarRange(table: "ping_aggregates", column: "timestamp_minute", from: f, to: t) > 0
        }
    }

    /// Returns true if any ping data exists for the given targets in the given time range.
    /// Used by the Network History time-window picker to disable buttons for windows where
    /// the selected target has no data (even if other targets do).
    /// UUID strings contain only hex digits and hyphens so embedding them directly is safe.
    public func hasPingData(forTargetIDs targetIDs: [UUID], from: Date, to: Date) -> Bool {
        guard !targetIDs.isEmpty else { return hasPingData(from: from, to: to) }
        let f   = from.timeIntervalSince1970
        let t   = to.timeIntervalSince1970
        let ids = targetIDs.map { "'\($0.uuidString)'" }.joined(separator: ",")
        return queue.sync {
            _scalar("SELECT 1 FROM ping_samples    WHERE target_id IN (\(ids)) AND timestamp        >= \(f) AND timestamp        <= \(t) LIMIT 1;") > 0
         || _scalar("SELECT 1 FROM ping_aggregates WHERE target_id IN (\(ids)) AND timestamp_minute >= \(f) AND timestamp_minute <= \(t) LIMIT 1;") > 0
        }
    }

    /// Count of raw ping samples across all targets (useful for diagnostics).
    public func rawPingCount() -> Int {
        queue.sync { _scalar("SELECT COUNT(*) FROM ping_samples;") }
    }

    /// Count of per-minute aggregate rows across all targets.
    public func aggregateCount() -> Int {
        queue.sync { _scalar("SELECT COUNT(*) FROM ping_aggregates;") }
    }

    /// Estimated database file size in bytes (0 for in-memory databases).
    public var databaseSizeBytes: Int64 {
        guard path != ":memory:" else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    // MARK: - Internal convenience wrappers (used by tests via @testable import)

    /// Convenience wrapper for tests — extracts primitives from a Core PingResult.
    func insertPing(_ result: PingResult,
                    targetID: UUID,
                    targetLabel: String,
                    host: String) {
        insertPing(timestamp: result.timestamp,
                   rtt: result.rtt,
                   lossPercent: result.lossPercent,
                   jitter: result.jitter,
                   targetID: targetID,
                   targetLabel: targetLabel,
                   host: host)
    }

    /// Convenience wrapper for tests — extracts primitives from a Core WiFiSnapshot.
    func insertWiFi(_ snapshot: WiFiSnapshot, sessionID: UUID? = nil) {
        insertWiFi(timestamp:      snapshot.timestamp,
                   rssi:           snapshot.rssi,
                   noise:          snapshot.noise,
                   snr:            snapshot.snr,
                   channel:        snapshot.channelNumber,
                   bandGHz:        snapshot.channelBandGHz,
                   txRateMbps:     snapshot.txRateMbps,
                   phyMode:        snapshot.phyMode,
                   interfaceName:  snapshot.interfaceName,
                   ipAddress:      snapshot.ipAddress,
                   routerIP:       snapshot.routerIP,
                   sessionID:      sessionID)
    }

    /// Convenience wrapper for tests — takes Core MetricStatus instead of raw Int.
    func openIncident(id: UUID, severity: MetricStatus, cause: String, startTime: Date = .init()) {
        openIncident(id: id, severityRaw: severity.rawValue, cause: cause, startTime: startTime)
    }

    /// Convenience wrapper for tests — takes Core MetricStatus instead of raw Int.
    func closeIncident(id: UUID, endTime: Date = .init(), peakSeverity: MetricStatus) {
        closeIncident(id: id, endTime: endTime, peakSeverityRaw: peakSeverity.rawValue)
    }

    /// Convenience wrapper for tests — takes Core MetricStatus instead of raw Int.
    func updateIncidentSeverity(id: UUID, peakSeverity: MetricStatus) {
        updateIncidentSeverity(id: id, peakSeverityRaw: peakSeverity.rawValue)
    }

    // MARK: - Test helper

    /// Blocks until all pending async operations have completed. For use in tests only.
    func waitForPendingOps() {
        queue.sync {}
    }

    // MARK: - Private: database open / schema

    private func _open() {
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir,
                                                      withIntermediateDirectories: true)
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            // Corrupted on-disk DB: wipe and retry
            if path != ":memory:" { try? FileManager.default.removeItem(atPath: path) }
            if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
                // Last resort: fall back to an in-memory database
                sqlite3_open_v2(":memory:", &db, flags, nil)
            }
        }
        _exec("PRAGMA journal_mode = WAL;")
        _exec("PRAGMA synchronous = NORMAL;")
        _exec("PRAGMA foreign_keys = ON;")
        _exec("PRAGMA cache_size = -4000;")   // 4 MB page cache
    }

    private func _createSchema() {
        _exec("""
            CREATE TABLE IF NOT EXISTS ping_samples (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp    REAL    NOT NULL,
                target_id    TEXT    NOT NULL,
                target_label TEXT    NOT NULL,
                host         TEXT    NOT NULL,
                rtt_ms       REAL,
                loss_pct     REAL    NOT NULL,
                jitter_ms    REAL
            );
            CREATE TABLE IF NOT EXISTS wifi_samples (
                id             INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp      REAL    NOT NULL,
                rssi           INTEGER NOT NULL,
                noise          INTEGER NOT NULL,
                snr            INTEGER NOT NULL,
                channel        INTEGER NOT NULL,
                band_ghz       REAL    NOT NULL,
                tx_rate_mbps   REAL    NOT NULL,
                phy_mode       TEXT    NOT NULL,
                interface_name TEXT    NOT NULL,
                ip_address     TEXT,
                router_ip      TEXT
            );
            CREATE TABLE IF NOT EXISTS ping_aggregates (
                timestamp_minute REAL    NOT NULL,
                target_id        TEXT    NOT NULL,
                sample_count     INTEGER NOT NULL,
                avg_rtt          REAL,
                max_rtt          REAL,
                avg_loss         REAL    NOT NULL,
                avg_jitter       REAL,
                PRIMARY KEY (timestamp_minute, target_id)
            );
            CREATE TABLE IF NOT EXISTS incidents (
                id                TEXT    PRIMARY KEY,
                started_at        REAL    NOT NULL,
                ended_at          REAL,
                severity_raw      INTEGER NOT NULL,
                peak_severity_raw INTEGER NOT NULL,
                cause             TEXT    NOT NULL
            );
            CREATE TABLE IF NOT EXISTS speedtest_results (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp   REAL    NOT NULL,
                dl_mbps     REAL    NOT NULL,
                ul_mbps     REAL    NOT NULL,
                latency_ms  REAL    NOT NULL,
                jitter_ms   REAL    NOT NULL,
                isp         TEXT    NOT NULL DEFAULT '',
                server_name TEXT    NOT NULL DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS network_sessions (
                id           TEXT    PRIMARY KEY,
                fingerprint  TEXT    NOT NULL,
                display_name TEXT    NOT NULL,
                started_at   REAL    NOT NULL,
                last_seen    REAL    NOT NULL
            );
            CREATE TABLE IF NOT EXISTS dns_samples (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp   REAL    NOT NULL,
                hostname    TEXT    NOT NULL,
                resolve_ms  REAL,
                session_id  TEXT
            );
            CREATE TABLE IF NOT EXISTS interface_errors (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp   REAL    NOT NULL,
                iface       TEXT    NOT NULL,
                errors_in   INTEGER NOT NULL DEFAULT 0,
                errors_out  INTEGER NOT NULL DEFAULT 0,
                drops_in    INTEGER NOT NULL DEFAULT 0,
                session_id  TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_ping_target_time     ON ping_samples(target_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_wifi_time            ON wifi_samples(timestamp);
            CREATE INDEX IF NOT EXISTS idx_incidents_time       ON incidents(started_at);
            CREATE INDEX IF NOT EXISTS idx_speedtest_time       ON speedtest_results(timestamp);
            CREATE INDEX IF NOT EXISTS idx_sessions_fingerprint ON network_sessions(fingerprint);
            CREATE INDEX IF NOT EXISTS idx_sessions_time        ON network_sessions(started_at);
            CREATE INDEX IF NOT EXISTS idx_dns_session          ON dns_samples(session_id);
            CREATE INDEX IF NOT EXISTS idx_dns_time             ON dns_samples(timestamp);
            CREATE INDEX IF NOT EXISTS idx_iferr_session        ON interface_errors(session_id);
            CREATE TABLE IF NOT EXISTS mtu_checks (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp    REAL    NOT NULL,
                host         TEXT    NOT NULL,
                payload_bytes INTEGER NOT NULL,
                reachable    INTEGER NOT NULL DEFAULT 0,
                rtt_ms       REAL,
                session_id   TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_mtu_session ON mtu_checks(session_id);
            CREATE TABLE IF NOT EXISTS dns_resolver_samples (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp     REAL    NOT NULL,
                resolver_ip   TEXT    NOT NULL,
                resolver_name TEXT    NOT NULL,
                query_host    TEXT    NOT NULL,
                resolve_ms    REAL,
                rcode         INTEGER,
                session_id    TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_dnsres_session  ON dns_resolver_samples(session_id);
            CREATE INDEX IF NOT EXISTS idx_dnsres_time     ON dns_resolver_samples(timestamp);
            CREATE INDEX IF NOT EXISTS idx_dnsres_ip_time  ON dns_resolver_samples(resolver_ip, timestamp);

            CREATE TABLE IF NOT EXISTS traceroute_events (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id        TEXT,
                timestamp         REAL    NOT NULL,
                target_host       TEXT    NOT NULL,
                output            TEXT    NOT NULL,
                hop_count         INTEGER,
                trigger_rtt_ms    REAL,
                trigger_loss_pct  REAL
            );
            CREATE INDEX IF NOT EXISTS idx_traceroute_session  ON traceroute_events(session_id);
            CREATE INDEX IF NOT EXISTS idx_traceroute_time     ON traceroute_events(timestamp);

            CREATE TABLE IF NOT EXISTS connection_profiles (
                fingerprint              TEXT    PRIMARY KEY,
                display_name             TEXT    NOT NULL,
                stealth_mode             INTEGER NOT NULL DEFAULT 0,
                stealth_probe_port       INTEGER,
                stealth_detected_at      REAL,
                stealth_source           TEXT,
                icmp_last_ok_at          REAL,
                icmp_throttled           INTEGER NOT NULL DEFAULT 0,
                icmp_throttled_at        REAL,
                preferred_poll_interval  REAL,
                poll_interval_source     TEXT,
                first_seen               REAL    NOT NULL,
                last_seen                REAL    NOT NULL,
                total_sessions           INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_connprofile_lastseen ON connection_profiles(last_seen);

            CREATE TABLE IF NOT EXISTS system_events (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp  REAL    NOT NULL,
                event_type TEXT    NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_system_events_ts ON system_events(timestamp);
            """)
    }

    // MARK: - Private: migrations

    /// Idempotent ALTER TABLE migrations — SQLite returns an error if the column
    /// already exists, which `_exec` silently discards.
    private func _runMigrations() {
        _exec("ALTER TABLE ping_samples  ADD COLUMN session_id TEXT;")
        _exec("ALTER TABLE wifi_samples  ADD COLUMN session_id TEXT;")
        _exec("CREATE INDEX IF NOT EXISTS idx_ping_session  ON ping_samples(session_id);")
        _exec("CREATE INDEX IF NOT EXISTS idx_wifi_session  ON wifi_samples(session_id);")
        // v2.22.2: connection type and weak-fingerprint flag on network sessions.
        // _exec silently discards SQLITE_ERROR when the column already exists — idempotent.
        _exec("ALTER TABLE network_sessions ADD COLUMN connection_type  TEXT    NOT NULL DEFAULT 'wifi';")
        _exec("ALTER TABLE network_sessions ADD COLUMN weak_fingerprint INTEGER NOT NULL DEFAULT 0;")
        // v2.34.0: VPN/tunnel interface name at session open time.
        _exec("ALTER TABLE network_sessions ADD COLUMN vpn_interface TEXT;")
        // v2.40.0: ISP/ASN name resolved at session open time.
        _exec("ALTER TABLE network_sessions ADD COLUMN isp_name TEXT;")
        // v2.45.0: user-assigned label for connection profiles.
        _exec("ALTER TABLE connection_profiles ADD COLUMN user_label TEXT;")
        // v2.49.0: user note on incidents.
        _exec("ALTER TABLE incidents ADD COLUMN note TEXT;")
        // v2.54.0: per-session learned latency baseline (median of first 30 min).
        _exec("ALTER TABLE network_sessions ADD COLUMN baseline_rtt_ms REAL;")
    }

    // MARK: - Private: insert implementations

    private func _insertPing(ts: Double, targetID: String, label: String, host: String,
                              rtt: Double?, loss: Double, jitter: Double?,
                              sessionID: String? = nil) {
        let sql = """
            INSERT INTO ping_samples
                (timestamp, target_id, target_label, host, rtt_ms, loss_pct, jitter_ms, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        _bindText(stmt, 2, targetID)
        _bindText(stmt, 3, label)
        _bindText(stmt, 4, host)
        if let v = rtt      { sqlite3_bind_double(stmt, 5, v) } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_double(stmt, 6, loss)
        if let v = jitter   { sqlite3_bind_double(stmt, 7, v) } else { sqlite3_bind_null(stmt, 7) }
        if let v = sessionID { _bindText(stmt, 8, v) }         else { sqlite3_bind_null(stmt, 8) }
        sqlite3_step(stmt)
    }

    private func _insertWiFi(ts: Double, rssi: Int, noise: Int, snr: Int,
                              channel: Int, bandGHz: Double, txRate: Double,
                              phyMode: String, iface: String,
                              ip: String?, gw: String?,
                              sessionID: String? = nil) {
        let sql = """
            INSERT INTO wifi_samples
                (timestamp, rssi, noise, snr, channel, band_ghz, tx_rate_mbps,
                 phy_mode, interface_name, ip_address, router_ip, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        sqlite3_bind_int(stmt, 2, Int32(rssi))
        sqlite3_bind_int(stmt, 3, Int32(noise))
        sqlite3_bind_int(stmt, 4, Int32(snr))
        sqlite3_bind_int(stmt, 5, Int32(channel))
        sqlite3_bind_double(stmt, 6, bandGHz)
        sqlite3_bind_double(stmt, 7, txRate)
        _bindText(stmt, 8, phyMode)
        _bindText(stmt, 9, iface)
        if let v = ip        { _bindText(stmt, 10, v) } else { sqlite3_bind_null(stmt, 10) }
        if let v = gw        { _bindText(stmt, 11, v) } else { sqlite3_bind_null(stmt, 11) }
        if let v = sessionID { _bindText(stmt, 12, v) } else { sqlite3_bind_null(stmt, 12) }
        sqlite3_step(stmt)
    }

    private func _insertSpeedtest(ts: Double, dl: Double, ul: Double,
                                   lat: Double, jit: Double, isp: String, server: String) {
        let sql = """
            INSERT INTO speedtest_results (timestamp, dl_mbps, ul_mbps, latency_ms, jitter_ms, isp, server_name)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        sqlite3_bind_double(stmt, 2, dl)
        sqlite3_bind_double(stmt, 3, ul)
        sqlite3_bind_double(stmt, 4, lat)
        sqlite3_bind_double(stmt, 5, jit)
        _bindText(stmt, 6, isp)
        _bindText(stmt, 7, server)
        sqlite3_step(stmt)
    }

    private func _insertDNS(ts: Double, hostname: String, resolveMs: Double?, sessionID: String?) {
        let sql = """
            INSERT INTO dns_samples (timestamp, hostname, resolve_ms, session_id)
            VALUES (?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        _bindText(stmt, 2, hostname)
        if let v = resolveMs  { sqlite3_bind_double(stmt, 3, v) } else { sqlite3_bind_null(stmt, 3) }
        if let v = sessionID  { _bindText(stmt, 4, v) }           else { sqlite3_bind_null(stmt, 4) }
        sqlite3_step(stmt)
    }

    private func _insertInterfaceErrors(ts: Double, iface: String,
                                         errorsIn: Int64, errorsOut: Int64,
                                         dropsIn: Int64, sessionID: String?) {
        let sql = """
            INSERT INTO interface_errors
                (timestamp, iface, errors_in, errors_out, drops_in, session_id)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        _bindText(stmt, 2, iface)
        sqlite3_bind_int64(stmt, 3, errorsIn)
        sqlite3_bind_int64(stmt, 4, errorsOut)
        sqlite3_bind_int64(stmt, 5, dropsIn)
        if let v = sessionID { _bindText(stmt, 6, v) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_step(stmt)
    }

    private func _openIncident(id: String, ts: Double, severity: Int, cause: String) {
        let sql = """
            INSERT OR IGNORE INTO incidents
                (id, started_at, severity_raw, peak_severity_raw, cause)
            VALUES (?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, id)
        sqlite3_bind_double(stmt, 2, ts)
        sqlite3_bind_int(stmt, 3, Int32(severity))
        sqlite3_bind_int(stmt, 4, Int32(severity))
        _bindText(stmt, 5, cause)
        sqlite3_step(stmt)
    }

    private func _closeIncident(id: String, endTs: Double, peak: Int) {
        let sql = "UPDATE incidents SET ended_at = ?, peak_severity_raw = MAX(peak_severity_raw, ?) WHERE id = ?;"
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, endTs)
        sqlite3_bind_int(stmt, 2, Int32(peak))
        _bindText(stmt, 3, id)
        sqlite3_step(stmt)
    }

    private func _updateIncidentSeverity(id: String, peak: Int) {
        let sql = "UPDATE incidents SET peak_severity_raw = MAX(peak_severity_raw, ?) WHERE id = ?;"
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(peak))
        _bindText(stmt, 2, id)
        sqlite3_step(stmt)
    }

    // MARK: - Private: aggregation

    private func _aggregate(before cutoff: Double) {
        // Roll raw samples into per-minute buckets per target.
        // AVG(rtt_ms) ignores NULLs (timeouts), which is the desired behaviour —
        // max_rtt stays NULL for all-timeout minutes, signalling full outage.
        let sql = """
            INSERT OR REPLACE INTO ping_aggregates
                (timestamp_minute, target_id, sample_count, avg_rtt, max_rtt, avg_loss, avg_jitter)
            SELECT
                CAST(timestamp / 60 AS INTEGER) * 60,
                target_id,
                COUNT(*),
                AVG(rtt_ms),
                MAX(rtt_ms),
                AVG(loss_pct),
                AVG(jitter_ms)
            FROM ping_samples
            WHERE timestamp < \(cutoff)
            GROUP BY CAST(timestamp / 60 AS INTEGER), target_id;
            """
        _exec(sql)
    }

    // MARK: - Private: query implementations

    private func _pingRows(targetID: String, from: Double, to: Double) -> [PingRow] {
        let sql = """
            SELECT timestamp, rtt_ms, loss_pct, jitter_ms
            FROM ping_samples
            WHERE target_id = ? AND timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, targetID)
        sqlite3_bind_double(stmt, 2, from)
        sqlite3_bind_double(stmt, 3, to)
        return _collectPingRows(stmt, targetID: targetID)
    }

    private func _aggRows(targetID: String, from: Double, to: Double) -> [PingRow] {
        let sql = """
            SELECT timestamp_minute, avg_rtt, avg_loss, avg_jitter
            FROM ping_aggregates
            WHERE target_id = ? AND timestamp_minute >= ? AND timestamp_minute <= ?
            ORDER BY timestamp_minute ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, targetID)
        sqlite3_bind_double(stmt, 2, from)
        sqlite3_bind_double(stmt, 3, to)
        return _collectPingRows(stmt, targetID: targetID)
    }

    private func _collectPingRows(_ stmt: OpaquePointer, targetID: String) -> [PingRow] {
        let uuid = UUID(uuidString: targetID) ?? UUID()
        var rows: [PingRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts     = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let rtt    = sqlite3_column_type(stmt, 1) != SQLITE_NULL ? sqlite3_column_double(stmt, 1) : nil as Double?
            let loss   = sqlite3_column_double(stmt, 2)
            let jitter = sqlite3_column_type(stmt, 3) != SQLITE_NULL ? sqlite3_column_double(stmt, 3) : nil as Double?
            rows.append(PingRow(timestamp: ts, targetID: uuid, rttMs: rtt, lossPct: loss, jitterMs: jitter))
        }
        return rows
    }

    private func _wifiRows(from: Double, to: Double) -> [WiFiRow] {
        let sql = """
            SELECT timestamp, rssi, snr, channel, band_ghz, tx_rate_mbps
            FROM wifi_samples
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from)
        sqlite3_bind_double(stmt, 2, to)
        var rows: [WiFiRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(WiFiRow(
                timestamp:     Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                rssi:          Int(sqlite3_column_int(stmt, 1)),
                snr:           Int(sqlite3_column_int(stmt, 2)),
                channelNumber: Int(sqlite3_column_int(stmt, 3)),
                bandGHz:       sqlite3_column_double(stmt, 4),
                txRateMbps:    sqlite3_column_double(stmt, 5)
            ))
        }
        return rows
    }

    private func _speedtestRows(from: Double, to: Double) -> [SpeedtestRow] {
        let sql = """
            SELECT timestamp, dl_mbps, ul_mbps, latency_ms, jitter_ms, isp, server_name
            FROM speedtest_results
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from)
        sqlite3_bind_double(stmt, 2, to)
        var rows: [SpeedtestRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts     = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let dl     = sqlite3_column_double(stmt, 1)
            let ul     = sqlite3_column_double(stmt, 2)
            let lat    = sqlite3_column_double(stmt, 3)
            let jit    = sqlite3_column_double(stmt, 4)
            let isp    = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let server = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            rows.append(SpeedtestRow(timestamp: ts, downloadMbps: dl, uploadMbps: ul,
                                     latencyMs: lat, jitterMs: jit, isp: isp, serverName: server))
        }
        return rows
    }

    // MARK: - Private: session implementations

    private func _openSession(id: String, fingerprint: String, displayName: String,
                               connectionType: String, weakFingerprint: Int,
                               vpnInterface: String?, ts: Double) {
        let sql = """
            INSERT OR IGNORE INTO network_sessions
                (id, fingerprint, display_name, started_at, last_seen,
                 connection_type, weak_fingerprint, vpn_interface)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, id)
        _bindText(stmt, 2, fingerprint)
        _bindText(stmt, 3, displayName)
        sqlite3_bind_double(stmt, 4, ts)
        sqlite3_bind_double(stmt, 5, ts)
        _bindText(stmt, 6, connectionType)
        sqlite3_bind_int(stmt, 7, Int32(weakFingerprint))
        if let vpn = vpnInterface { _bindText(stmt, 8, vpn) }
        else { sqlite3_bind_null(stmt, 8) }
        sqlite3_step(stmt)
    }

    private func _touchSession(id: String, ts: Double) {
        let sql = "UPDATE network_sessions SET last_seen = ? WHERE id = ?;"
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        _bindText(stmt, 2, id)
        sqlite3_step(stmt)
    }

    private func _latestSession(fingerprint: String) -> NetworkSessionRow? {
        let sql = """
            SELECT id, fingerprint, display_name, started_at, last_seen,
                   connection_type, weak_fingerprint, vpn_interface, isp_name, baseline_rtt_ms
            FROM network_sessions
            WHERE fingerprint = ?
            ORDER BY started_at DESC
            LIMIT 1;
            """
        guard let stmt = _prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, fingerprint)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return _sessionRow(stmt)
    }

    private func _sessionsInRange(from: Double, to: Double) -> [NetworkSessionRow] {
        // A session overlaps [from, to] if it started before `to` and last_seen >= from.
        let sql = """
            SELECT id, fingerprint, display_name, started_at, last_seen,
                   connection_type, weak_fingerprint, vpn_interface, isp_name, baseline_rtt_ms
            FROM network_sessions
            WHERE started_at <= ? AND last_seen >= ?
            ORDER BY started_at ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, to)
        sqlite3_bind_double(stmt, 2, from)
        var rows: [NetworkSessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let r = _sessionRow(stmt) { rows.append(r) }
        }
        return rows
    }

    private func _sessionRow(_ stmt: OpaquePointer) -> NetworkSessionRow? {
        guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let id    = UUID(uuidString: idStr) else { return nil }
        let fp             = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let name           = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let startedAt      = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let lastSeen       = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let connType       = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "wifi"
        let weakFP         = sqlite3_column_int(stmt, 6) != 0
        let vpnIface       = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let ispName        = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
        let baselineRTT    = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? sqlite3_column_double(stmt, 9) : nil as Double?
        return NetworkSessionRow(id: id, fingerprint: fp, displayName: name,
                                 startedAt: startedAt, lastSeen: lastSeen,
                                 connectionType: connType, weakFingerprint: weakFP,
                                 vpnInterface: vpnIface, ispName: ispName,
                                 learnedBaselineRTT: baselineRTT)
    }

    private func _pingRows(targetID: String, sessionID: String) -> [PingRow] {
        let sql = """
            SELECT timestamp, rtt_ms, loss_pct, jitter_ms
            FROM ping_samples
            WHERE target_id = ? AND session_id = ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, targetID)
        _bindText(stmt, 2, sessionID)
        return _collectPingRows(stmt, targetID: targetID)
    }

    private func _wifiRows(sessionID: String) -> [WiFiRow] {
        let sql = """
            SELECT timestamp, rssi, snr, channel, band_ghz, tx_rate_mbps
            FROM wifi_samples
            WHERE session_id = ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, sessionID)
        var rows: [WiFiRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(WiFiRow(
                timestamp:     Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                rssi:          Int(sqlite3_column_int(stmt, 1)),
                snr:           Int(sqlite3_column_int(stmt, 2)),
                channelNumber: Int(sqlite3_column_int(stmt, 3)),
                bandGHz:       sqlite3_column_double(stmt, 4),
                txRateMbps:    sqlite3_column_double(stmt, 5)
            ))
        }
        return rows
    }

    private func _dnsRows(sessionID: String) -> [DnsRow] {
        let sql = """
            SELECT timestamp, hostname, resolve_ms
            FROM dns_samples
            WHERE session_id = ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, sessionID)
        var rows: [DnsRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts       = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let hostname = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let ms       = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                         ? sqlite3_column_double(stmt, 2) : nil as Double?
            rows.append(DnsRow(timestamp: ts, hostname: hostname, resolveMs: ms))
        }
        return rows
    }

    private func _interfaceErrorRows(sessionID: String) -> [InterfaceErrorRow] {
        let sql = """
            SELECT timestamp, iface, errors_in, errors_out, drops_in
            FROM interface_errors
            WHERE session_id = ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, sessionID)
        var rows: [InterfaceErrorRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts    = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let iface = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            rows.append(InterfaceErrorRow(
                timestamp:  ts,
                iface:      iface,
                errorsIn:   sqlite3_column_int64(stmt, 2),
                errorsOut:  sqlite3_column_int64(stmt, 3),
                dropsIn:    sqlite3_column_int64(stmt, 4)
            ))
        }
        return rows
    }

    private func _insertMTUCheck(ts: Double, host: String, payloadBytes: Int,
                                  reachable: Bool, rttMs: Double?, sessionID: String?) {
        let sql = """
            INSERT INTO mtu_checks (timestamp, host, payload_bytes, reachable, rtt_ms, session_id)
            VALUES (?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        _bindText(stmt, 2, host)
        sqlite3_bind_int(stmt, 3, Int32(payloadBytes))
        sqlite3_bind_int(stmt, 4, reachable ? 1 : 0)
        if let rttMs { sqlite3_bind_double(stmt, 5, rttMs) } else { sqlite3_bind_null(stmt, 5) }
        if let sid = sessionID { _bindText(stmt, 6, sid) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_step(stmt)
    }

    private func _mtuRows(sessionID: String) -> [MTURow] {
        let sql = """
            SELECT timestamp, host, payload_bytes, reachable, rtt_ms
            FROM mtu_checks
            WHERE session_id = ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, sessionID)
        var rows: [MTURow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts           = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let host         = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let payloadBytes = Int(sqlite3_column_int(stmt, 2))
            let reachable    = sqlite3_column_int(stmt, 3) != 0
            let rttMs: Double? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                              ? sqlite3_column_double(stmt, 4) : nil
            rows.append(MTURow(timestamp: ts, host: host, payloadBytes: payloadBytes,
                               reachable: reachable, rttMs: rttMs))
        }
        return rows
    }

    private func _insertDNSResolverSample(ts: Double, resolverIP: String, resolverName: String,
                                           queryHost: String, resolveMs: Double?, rcode: Int?,
                                           sessionID: String?) {
        let sql = """
            INSERT INTO dns_resolver_samples
                (timestamp, resolver_ip, resolver_name, query_host, resolve_ms, rcode, session_id)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        _bindText(stmt, 2, resolverIP)
        _bindText(stmt, 3, resolverName)
        _bindText(stmt, 4, queryHost)
        if let ms = resolveMs { sqlite3_bind_double(stmt, 5, ms) } else { sqlite3_bind_null(stmt, 5) }
        if let rc = rcode     { sqlite3_bind_int(stmt, 6, Int32(rc)) } else { sqlite3_bind_null(stmt, 6) }
        if let sid = sessionID { _bindText(stmt, 7, sid) } else { sqlite3_bind_null(stmt, 7) }
        sqlite3_step(stmt)
    }

    private func _dnsResolverRows(sessionID: String) -> [DNSResolverRow] {
        let sql = """
            SELECT timestamp, resolver_ip, resolver_name, query_host, resolve_ms, rcode
            FROM dns_resolver_samples
            WHERE session_id = ?
            ORDER BY timestamp ASC;
            """
        return _fetchDNSResolverRows(sql: sql, bind: { stmt in _bindText(stmt, 1, sessionID) })
    }

    private func _dnsResolverRowsInRange(from: Double, to: Double) -> [DNSResolverRow] {
        let sql = """
            SELECT timestamp, resolver_ip, resolver_name, query_host, resolve_ms, rcode
            FROM dns_resolver_samples
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC;
            """
        return _fetchDNSResolverRows(sql: sql) { stmt in
            sqlite3_bind_double(stmt, 1, from)
            sqlite3_bind_double(stmt, 2, to)
        }
    }

    /// Shared row-mapping logic for DNS resolver result sets.
    private func _fetchDNSResolverRows(sql: String,
                                        bind: (OpaquePointer) -> Void) -> [DNSResolverRow] {
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [DNSResolverRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts   = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let ip   = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let host = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let ms: Double? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                            ? sqlite3_column_double(stmt, 4) : nil
            let rc: Int?    = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                            ? Int(sqlite3_column_int(stmt, 5)) : nil
            rows.append(DNSResolverRow(timestamp: ts, resolverIP: ip, resolverName: name,
                                       queryHost: host, resolveMs: ms, rcode: rc))
        }
        return rows
    }

    private func _insertTracerouteEvent(sessionID: String?, timestamp: Double,
                                         targetHost: String, output: String,
                                         hopCount: Int?, triggerRTTMs: Double?,
                                         triggerLossPct: Double?) {
        let sql = """
            INSERT INTO traceroute_events
                (session_id, timestamp, target_host, output,
                 hop_count, trigger_rtt_ms, trigger_loss_pct)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        if let sid = sessionID { _bindText(stmt, 1, sid) } else { sqlite3_bind_null(stmt, 1) }
        sqlite3_bind_double(stmt, 2, timestamp)
        _bindText(stmt, 3, targetHost)
        _bindText(stmt, 4, output)
        if let hc = hopCount  { sqlite3_bind_int(stmt, 5, Int32(hc)) } else { sqlite3_bind_null(stmt, 5) }
        if let rtt = triggerRTTMs  { sqlite3_bind_double(stmt, 6, rtt) } else { sqlite3_bind_null(stmt, 6) }
        if let lp  = triggerLossPct { sqlite3_bind_double(stmt, 7, lp)  } else { sqlite3_bind_null(stmt, 7) }
        sqlite3_step(stmt)
    }

    private func _tracerouteEvents(sessionID: String) -> [TracerouteEventRow] {
        let sql = """
            SELECT id, session_id, timestamp, target_host, output,
                   hop_count, trigger_rtt_ms, trigger_loss_pct
            FROM traceroute_events
            WHERE session_id = ?
            ORDER BY timestamp ASC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, sessionID)
        var rows: [TracerouteEventRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowID     = sqlite3_column_int64(stmt, 0)
            let sidStr    = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let sessionUUID = sidStr.flatMap { UUID(uuidString: $0) }
            let ts        = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let host      = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let output    = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let hc: Int?  = sqlite3_column_type(stmt, 5) != SQLITE_NULL
                          ? Int(sqlite3_column_int(stmt, 5)) : nil
            let rtt: Double? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                             ? sqlite3_column_double(stmt, 6) : nil
            let lp: Double?  = sqlite3_column_type(stmt, 7) != SQLITE_NULL
                             ? sqlite3_column_double(stmt, 7) : nil
            rows.append(TracerouteEventRow(id: rowID, sessionID: sessionUUID,
                                           timestamp: ts, targetHost: host, output: output,
                                           hopCount: hc, triggerRTTMs: rtt,
                                           triggerLossPct: lp))
        }
        return rows
    }

    private func _hourlyRTTAverages(since: Double, minSampleCount: Int) -> [Int: Double] {
        // Use localtime modifier so hours reflect the user's clock, not UTC.
        // ping_aggregates columns: timestamp_minute (unix seconds), avg_rtt (nullable)
        let sql = """
            SELECT
                CAST(strftime('%H', datetime(timestamp_minute, 'unixepoch', 'localtime')) AS INTEGER) AS hour,
                AVG(avg_rtt) AS avg_rtt,
                COUNT(*)     AS n
            FROM ping_aggregates
            WHERE timestamp_minute >= ? AND avg_rtt IS NOT NULL
            GROUP BY hour
            HAVING n >= ?
            ORDER BY hour;
            """
        guard let stmt = _prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since)
        sqlite3_bind_int(stmt, 2, Int32(minSampleCount))
        var result: [Int: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let hour   = Int(sqlite3_column_int(stmt, 0))
            let avgRTT = sqlite3_column_double(stmt, 1)
            result[hour] = avgRTT
        }
        return result
    }

    private func _weekdayRTTAverages(since: Double, minSampleCount: Int) -> [Int: Double] {
        // strftime('%w') returns 0=Sunday … 6=Saturday in localtime.
        let sql = """
            SELECT
                CAST(strftime('%w', datetime(timestamp_minute, 'unixepoch', 'localtime')) AS INTEGER) AS wd,
                AVG(avg_rtt) AS avg_rtt,
                COUNT(*)     AS n
            FROM ping_aggregates
            WHERE timestamp_minute >= ? AND avg_rtt IS NOT NULL
            GROUP BY wd
            HAVING n >= ?
            ORDER BY wd;
            """
        guard let stmt = _prepare(sql) else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since)
        sqlite3_bind_int(stmt, 2, Int32(minSampleCount))
        var result: [Int: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let wd     = Int(sqlite3_column_int(stmt, 0))
            let avgRTT = sqlite3_column_double(stmt, 1)
            result[wd] = avgRTT
        }
        return result
    }

    private func _incidents(limit: Int) -> [IncidentRow] {
        let sql = """
            SELECT id, started_at, ended_at, severity_raw, peak_severity_raw, cause, note
            FROM incidents
            ORDER BY started_at DESC
            LIMIT ?;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        return _collectIncidentRows(stmt: stmt)
    }

    private func _incidentsInRange(from: Double, to: Double, limit: Int) -> [IncidentRow] {
        let sql = """
            SELECT id, started_at, ended_at, severity_raw, peak_severity_raw, cause, note
            FROM incidents
            WHERE started_at >= ? AND started_at <= ?
            ORDER BY started_at DESC
            LIMIT ?;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from)
        sqlite3_bind_double(stmt, 2, to)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        return _collectIncidentRows(stmt: stmt)
    }

    private func _collectIncidentRows(stmt: OpaquePointer) -> [IncidentRow] {
        var rows: [IncidentRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let id    = UUID(uuidString: idStr) else { continue }
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let endedAt: Date? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)) : nil
            let note: String? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
                ? sqlite3_column_text(stmt, 6).map { String(cString: $0) } : nil
            rows.append(IncidentRow(
                id:               id,
                startedAt:        startedAt,
                endedAt:          endedAt,
                severityRaw:      Int(sqlite3_column_int(stmt, 3)),
                peakSeverityRaw:  Int(sqlite3_column_int(stmt, 4)),
                cause:            sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
                note:             note
            ))
        }
        return rows
    }

    // MARK: - Connection profiles (public API)

    /// Upsert a connection profile — creates or updates, preserving stealth/icmp state if already set.
    public func upsertConnectionProfile(fingerprint: String, displayName: String, now: Date = Date()) {
        let ts = now.timeIntervalSince1970
        queue.async { [weak self] in
            self?._upsertConnectionProfile(fingerprint: fingerprint, displayName: displayName, now: ts)
        }
    }

    /// Returns the profile for the given fingerprint, or nil if not found.
    public func connectionProfile(fingerprint: String) -> ConnectionProfile? {
        queue.sync { _connectionProfile(fingerprint: fingerprint) }
    }

    /// Returns all profiles, newest last_seen first.
    public func allConnectionProfiles() -> [ConnectionProfile] {
        queue.sync { _allConnectionProfiles() }
    }

    /// Enable or disable stealth mode for a network.
    public func setStealthMode(_ enabled: Bool, probePort: Int?, source: String?,
                               fingerprint: String, now: Date = Date()) {
        let ts = now.timeIntervalSince1970
        queue.async { [weak self] in
            self?._setStealthMode(enabled, probePort: probePort, source: source,
                                  fingerprint: fingerprint, now: ts)
        }
    }

    /// Record that ICMP is (or is not) throttled for a network.
    public func setICMPThrottled(_ throttled: Bool, fingerprint: String, now: Date = Date()) {
        let ts = now.timeIntervalSince1970
        queue.async { [weak self] in
            self?._setICMPThrottled(throttled, fingerprint: fingerprint, now: ts)
        }
    }

    /// Update the preferred poll interval override.
    public func setPreferredPollInterval(_ interval: Double?, source: String?,
                                        fingerprint: String) {
        queue.async { [weak self] in
            self?._setPreferredPollInterval(interval, source: source, fingerprint: fingerprint)
        }
    }

    /// Set or clear the user-assigned label for a profile.
    /// Pass nil to remove a previously set label.
    public func setConnectionProfileLabel(fingerprint: String, label: String?) {
        queue.async { [weak self] in self?._setConnectionProfileLabel(fingerprint: fingerprint, label: label) }
    }

    /// Permanently delete a connection profile and all associated state.
    public func deleteConnectionProfile(fingerprint: String) {
        queue.async { [weak self] in self?._deleteConnectionProfile(fingerprint: fingerprint) }
    }

    /// Advance last_seen and increment total_sessions for an existing profile.
    public func touchConnectionProfile(fingerprint: String, now: Date = Date()) {
        let ts = now.timeIntervalSince1970
        queue.async { [weak self] in
            self?._touchConnectionProfile(fingerprint: fingerprint, now: ts)
        }
    }

    /// Record that ICMP last responded successfully.
    public func updateICMPLastOk(fingerprint: String, now: Date = Date()) {
        let ts = now.timeIntervalSince1970
        queue.async { [weak self] in
            self?._updateICMPLastOk(fingerprint: fingerprint, now: ts)
        }
    }

    // MARK: - System events (sleep/wake)

    /// Records a sleep or wake event. Fire-and-forget.
    public func insertSystemEvent(timestamp: Date, eventType: String) {
        let ts = timestamp.timeIntervalSince1970
        queue.async { [weak self] in
            guard let self else { return }
            let sql = "INSERT INTO system_events (timestamp, event_type) VALUES (?, ?);"
            guard let stmt = _prepare(sql) else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            _bindText(stmt, 2, eventType)
            sqlite3_step(stmt)
        }
    }

    /// Returns system events (sleep/wake) within the given time range, ordered by timestamp.
    public func systemEventRows(from: Date, to: Date) -> [SystemEventRow] {
        let fromTs = from.timeIntervalSince1970
        let toTs   = to.timeIntervalSince1970
        return queue.sync {
            let sql = """
                SELECT timestamp, event_type FROM system_events
                WHERE timestamp >= ? AND timestamp <= ?
                ORDER BY timestamp ASC;
                """
            guard let stmt = _prepare(sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, fromTs)
            sqlite3_bind_double(stmt, 2, toTs)
            var rows: [SystemEventRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let ts   = sqlite3_column_double(stmt, 0)
                let type = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                rows.append(SystemEventRow(timestamp: Date(timeIntervalSince1970: ts),
                                          eventType: type))
            }
            return rows
        }
    }

    // MARK: - Connection profiles (private implementations)

    private func _upsertConnectionProfile(fingerprint: String, displayName: String, now: Double) {
        let sql = """
            INSERT INTO connection_profiles
                (fingerprint, display_name, first_seen, last_seen)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(fingerprint) DO UPDATE SET
                display_name   = excluded.display_name,
                last_seen      = excluded.last_seen,
                total_sessions = total_sessions + 1;
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, fingerprint)
        _bindText(stmt, 2, displayName)
        sqlite3_bind_double(stmt, 3, now)
        sqlite3_bind_double(stmt, 4, now)
        sqlite3_step(stmt)
    }

    private func _connectionProfile(fingerprint: String) -> ConnectionProfile? {
        let sql = """
            SELECT fingerprint, display_name, stealth_mode, stealth_probe_port,
                   stealth_detected_at, stealth_source, icmp_last_ok_at,
                   icmp_throttled, icmp_throttled_at, preferred_poll_interval,
                   poll_interval_source, first_seen, last_seen, total_sessions,
                   user_label
            FROM connection_profiles WHERE fingerprint = ? LIMIT 1;
            """
        guard let stmt = _prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, fingerprint)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return _collectConnectionProfile(stmt: stmt)
    }

    private func _allConnectionProfiles() -> [ConnectionProfile] {
        let sql = """
            SELECT fingerprint, display_name, stealth_mode, stealth_probe_port,
                   stealth_detected_at, stealth_source, icmp_last_ok_at,
                   icmp_throttled, icmp_throttled_at, preferred_poll_interval,
                   poll_interval_source, first_seen, last_seen, total_sessions,
                   user_label
            FROM connection_profiles ORDER BY last_seen DESC;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ConnectionProfile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let p = _collectConnectionProfile(stmt: stmt) { rows.append(p) }
        }
        return rows
    }

    private func _collectConnectionProfile(stmt: OpaquePointer) -> ConnectionProfile? {
        guard let fp = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { return nil }
        let displayName = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? fp
        let stealthMode = sqlite3_column_int(stmt, 2) != 0
        let probePort: Int? = sqlite3_column_type(stmt, 3) != SQLITE_NULL
            ? Int(sqlite3_column_int(stmt, 3)) : nil
        let detectedAt: Date? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)) : nil
        let source = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let icmpLastOk: Date? = sqlite3_column_type(stmt, 6) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)) : nil
        let icmpThrottled = sqlite3_column_int(stmt, 7) != 0
        let throttledAt: Date? = sqlite3_column_type(stmt, 8) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)) : nil
        let pollInterval: Double? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
            ? sqlite3_column_double(stmt, 9) : nil
        let pollSource = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let firstSeen = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        let lastSeen  = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        let totalSessions = Int(sqlite3_column_int(stmt, 13))
        let userLabel = sqlite3_column_text(stmt, 14).map { String(cString: $0) }
        return ConnectionProfile(
            fingerprint:           fp,
            displayName:           displayName,
            userLabel:             userLabel,
            stealthMode:           stealthMode,
            stealthProbePort:      probePort,
            stealthDetectedAt:     detectedAt,
            stealthSource:         source,
            icmpLastOkAt:          icmpLastOk,
            icmpThrottled:         icmpThrottled,
            icmpThrottledAt:       throttledAt,
            preferredPollInterval: pollInterval,
            pollIntervalSource:    pollSource,
            firstSeen:             firstSeen,
            lastSeen:              lastSeen,
            totalSessions:         totalSessions
        )
    }

    private func _setStealthMode(_ enabled: Bool, probePort: Int?, source: String?,
                                  fingerprint: String, now: Double) {
        let sql = """
            UPDATE connection_profiles SET
                stealth_mode        = ?,
                stealth_probe_port  = ?,
                stealth_detected_at = ?,
                stealth_source      = ?
            WHERE fingerprint = ?;
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, enabled ? 1 : 0)
        if let p = probePort { sqlite3_bind_int(stmt, 2, Int32(p)) }
        else                  { sqlite3_bind_null(stmt, 2) }
        if enabled { sqlite3_bind_double(stmt, 3, now) }
        else       { sqlite3_bind_null(stmt, 3) }
        if let s = source { _bindText(stmt, 4, s) }
        else               { sqlite3_bind_null(stmt, 4) }
        _bindText(stmt, 5, fingerprint)
        sqlite3_step(stmt)
    }

    private func _setICMPThrottled(_ throttled: Bool, fingerprint: String, now: Double) {
        let sql = """
            UPDATE connection_profiles SET
                icmp_throttled    = ?,
                icmp_throttled_at = ?
            WHERE fingerprint = ?;
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, throttled ? 1 : 0)
        if throttled { sqlite3_bind_double(stmt, 2, now) }
        else         { sqlite3_bind_null(stmt, 2) }
        _bindText(stmt, 3, fingerprint)
        sqlite3_step(stmt)
    }

    private func _setPreferredPollInterval(_ interval: Double?, source: String?,
                                           fingerprint: String) {
        let sql = """
            UPDATE connection_profiles SET
                preferred_poll_interval = ?,
                poll_interval_source    = ?
            WHERE fingerprint = ?;
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        if let i = interval { sqlite3_bind_double(stmt, 1, i) }
        else                 { sqlite3_bind_null(stmt, 1) }
        if let s = source { _bindText(stmt, 2, s) }
        else               { sqlite3_bind_null(stmt, 2) }
        _bindText(stmt, 3, fingerprint)
        sqlite3_step(stmt)
    }

    private func _touchConnectionProfile(fingerprint: String, now: Double) {
        let sql = """
            UPDATE connection_profiles SET
                last_seen      = ?,
                total_sessions = total_sessions + 1
            WHERE fingerprint = ?;
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now)
        _bindText(stmt, 2, fingerprint)
        sqlite3_step(stmt)
    }

    private func _updateICMPLastOk(fingerprint: String, now: Double) {
        let sql = "UPDATE connection_profiles SET icmp_last_ok_at = ? WHERE fingerprint = ?;"
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now)
        _bindText(stmt, 2, fingerprint)
        sqlite3_step(stmt)
    }

    private func _setConnectionProfileLabel(fingerprint: String, label: String?) {
        let sql = "UPDATE connection_profiles SET user_label = ? WHERE fingerprint = ?;"
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        if let l = label { _bindText(stmt, 1, l) } else { sqlite3_bind_null(stmt, 1) }
        _bindText(stmt, 2, fingerprint)
        sqlite3_step(stmt)
    }

    private func _deleteConnectionProfile(fingerprint: String) {
        let sql = "DELETE FROM connection_profiles WHERE fingerprint = ?;"
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, fingerprint)
        sqlite3_step(stmt)
    }

    private func _scalar(_ sql: String) -> Int {
        guard let stmt = _prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Private: SQLite helpers

    private func _prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    /// Bind a Swift String as UTF-8 text, instructing SQLite to copy it immediately.
    /// Passing the exact byte length handles strings containing embedded NUL characters.
    private func _bindText(_ stmt: OpaquePointer, _ col: Int32, _ value: String) {
        let utf8 = value.utf8
        sqlite3_bind_text(stmt, col, value, Int32(utf8.count), _SQLITE_TRANSIENT)
    }

    @discardableResult
    private func _exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK, let e = err {
            let _ = String(cString: e)   // suppress unused-result warning
            sqlite3_free(err)
        }
        return rc == SQLITE_OK
    }

    /// Parameterized DELETE helper — avoids string interpolation for timestamp cutoffs.
    /// Executes: DELETE FROM <table> WHERE <column> < ?
    private func _execDeleteBefore(table: String, column: String, cutoff: Double) {
        let sql = "DELETE FROM \(table) WHERE \(column) < ?;"
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, cutoff)
        sqlite3_step(stmt)
    }

    /// Parameterized range-existence check — avoids string interpolation for timestamps.
    /// Executes: SELECT 1 FROM <table> WHERE <column> >= ? AND <column> <= ? LIMIT 1
    private func _scalarRange(table: String, column: String, from: Double, to: Double) -> Int {
        let sql = "SELECT 1 FROM \(table) WHERE \(column) >= ? AND \(column) <= ? LIMIT 1;"
        guard let stmt = _prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from)
        sqlite3_bind_double(stmt, 2, to)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
