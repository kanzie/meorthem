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
            self?._exec("DELETE FROM ping_samples    WHERE timestamp < \(rawCutoff);")
            self?._exec("DELETE FROM wifi_samples    WHERE timestamp < \(rawCutoff);")
            self?._exec("DELETE FROM dns_samples     WHERE timestamp < \(rawCutoff);")
            self?._exec("DELETE FROM ping_aggregates WHERE timestamp_minute < \(aggCutoff);")
            self?._exec("DELETE FROM incidents WHERE ended_at IS NOT NULL AND ended_at < \(incCutoff);")
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

    public struct NetworkSessionRow: Identifiable {
        public let id: UUID
        public let fingerprint: String
        public let displayName: String
        public let startedAt: Date
        public let lastSeen: Date
    }

    public struct IncidentRow: Identifiable {
        public let id: UUID
        public let startedAt: Date
        public let endedAt: Date?
        public let severityRaw: Int
        public let peakSeverityRaw: Int
        public let cause: String

        public var isActive: Bool { endedAt == nil }
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
    public func openSession(id: UUID, fingerprint: String, displayName: String, startTime: Date = .init()) {
        let idStr = id.uuidString
        let ts    = startTime.timeIntervalSince1970
        queue.async { [weak self] in
            self?._openSession(id: idStr, fingerprint: fingerprint,
                               displayName: displayName, ts: ts)
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

    /// DNS resolution samples for a specific session (ascending).
    public func dnsRows(sessionID: UUID) -> [DnsRow] {
        queue.sync { _dnsRows(sessionID: sessionID.uuidString) }
    }

    /// Most-recent incidents, newest first. Queries both open and resolved events.
    public func recentIncidents(limit: Int = 100) -> [IncidentRow] {
        queue.sync { _incidents(limit: limit) }
    }

    /// Returns true if any ping data (raw or aggregated) exists in the given time range.
    /// Uses a LIMIT 1 query so it short-circuits immediately on the first matching row.
    public func hasPingData(from: Date, to: Date) -> Bool {
        let f = from.timeIntervalSince1970
        let t = to.timeIntervalSince1970
        return queue.sync {
            _scalar("SELECT 1 FROM ping_samples    WHERE timestamp         >= \(f) AND timestamp         <= \(t) LIMIT 1;") > 0
         || _scalar("SELECT 1 FROM ping_aggregates WHERE timestamp_minute  >= \(f) AND timestamp_minute  <= \(t) LIMIT 1;") > 0
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
            CREATE INDEX IF NOT EXISTS idx_ping_target_time     ON ping_samples(target_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_wifi_time            ON wifi_samples(timestamp);
            CREATE INDEX IF NOT EXISTS idx_incidents_time       ON incidents(started_at);
            CREATE INDEX IF NOT EXISTS idx_speedtest_time       ON speedtest_results(timestamp);
            CREATE INDEX IF NOT EXISTS idx_sessions_fingerprint ON network_sessions(fingerprint);
            CREATE INDEX IF NOT EXISTS idx_sessions_time        ON network_sessions(started_at);
            CREATE INDEX IF NOT EXISTS idx_dns_session          ON dns_samples(session_id);
            CREATE INDEX IF NOT EXISTS idx_dns_time             ON dns_samples(timestamp);
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

    private func _openSession(id: String, fingerprint: String, displayName: String, ts: Double) {
        let sql = """
            INSERT OR IGNORE INTO network_sessions
                (id, fingerprint, display_name, started_at, last_seen)
            VALUES (?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        _bindText(stmt, 1, id)
        _bindText(stmt, 2, fingerprint)
        _bindText(stmt, 3, displayName)
        sqlite3_bind_double(stmt, 4, ts)
        sqlite3_bind_double(stmt, 5, ts)
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
            SELECT id, fingerprint, display_name, started_at, last_seen
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
            SELECT id, fingerprint, display_name, started_at, last_seen
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
        let fp   = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let lastSeen  = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        return NetworkSessionRow(id: id, fingerprint: fp, displayName: name,
                                 startedAt: startedAt, lastSeen: lastSeen)
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

    private func _incidents(limit: Int) -> [IncidentRow] {
        let sql = """
            SELECT id, started_at, ended_at, severity_raw, peak_severity_raw, cause
            FROM incidents
            ORDER BY started_at DESC
            LIMIT ?;
            """
        guard let stmt = _prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [IncidentRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let id    = UUID(uuidString: idStr) else { continue }
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            let endedAt: Date? = sqlite3_column_type(stmt, 2) != SQLITE_NULL
                ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)) : nil
            rows.append(IncidentRow(
                id:               id,
                startedAt:        startedAt,
                endedAt:          endedAt,
                severityRaw:      Int(sqlite3_column_int(stmt, 3)),
                peakSeverityRaw:  Int(sqlite3_column_int(stmt, 4)),
                cause:            sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            ))
        }
        return rows
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
}
