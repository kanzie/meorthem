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
/// Data tiers managed automatically:
///   • `ping_samples`   — one row per poll per target; raw retention configurable (default 7 days)
///   • `wifi_samples`   — one row per WiFi snapshot; same raw retention
///   • `ping_aggregates`— per-minute roll-ups created from aged-out raw rows (default 90 days)
///   • `incidents`      — degradation event journal (default 1 year)
// Thread safety is managed entirely via `queue` — all mutable state (`db`) is only
// ever accessed on that serial queue. The @unchecked annotation opts out of the
// compiler's automatic Sendable checking, which cannot see through DispatchQueue.
final class SQLiteStore: @unchecked Sendable {

    // MARK: - Public factory

    static func makeDefault() -> SQLiteStore {
        SQLiteStore(path: Self.defaultDBPath)
    }

    static var defaultDBPath: String {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeOrThem", isDirectory: true)
        return dir.appendingPathComponent("metrics.db").path
    }

    // MARK: - Init / deinit

    let path: String

    init(path: String) {
        self.path = path
        queue.sync {
            self._open()
            self._createSchema()
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

    // MARK: - Insert (fire-and-forget, async)

    func insertPing(_ result: PingResult,
                    targetID: UUID,
                    targetLabel: String,
                    host: String) {
        let ts    = result.timestamp.timeIntervalSince1970
        let idStr = targetID.uuidString
        let rtt   = result.rtt
        let loss  = result.lossPercent
        let jit   = result.jitter
        queue.async { [weak self] in
            self?._insertPing(ts: ts, targetID: idStr, label: targetLabel,
                              host: host, rtt: rtt, loss: loss, jitter: jit)
        }
    }

    func insertWiFi(_ snapshot: WiFiSnapshot) {
        let ts   = snapshot.timestamp.timeIntervalSince1970
        let rssi = snapshot.rssi
        let noise = snapshot.noise
        let snr  = snapshot.snr
        let ch   = snapshot.channelNumber
        let band = snapshot.channelBandGHz
        let tx   = snapshot.txRateMbps
        let phy  = snapshot.phyMode
        let iface = snapshot.interfaceName
        let ip   = snapshot.ipAddress
        let gw   = snapshot.routerIP
        queue.async { [weak self] in
            self?._insertWiFi(ts: ts, rssi: rssi, noise: noise, snr: snr,
                              channel: ch, bandGHz: band, txRate: tx,
                              phyMode: phy, iface: iface, ip: ip, gw: gw)
        }
    }

    // MARK: - Incident journal (fire-and-forget)

    func openIncident(id: UUID, severity: MetricStatus, cause: String, startTime: Date = .init()) {
        let idStr = id.uuidString
        let ts    = startTime.timeIntervalSince1970
        let sev   = severity.rawValue
        queue.async { [weak self] in
            self?._openIncident(id: idStr, ts: ts, severity: sev, cause: cause)
        }
    }

    func closeIncident(id: UUID, endTime: Date = .init(), peakSeverity: MetricStatus) {
        let idStr = id.uuidString
        let ts    = endTime.timeIntervalSince1970
        let peak  = peakSeverity.rawValue
        queue.async { [weak self] in
            self?._closeIncident(id: idStr, endTs: ts, peak: peak)
        }
    }

    func updateIncidentSeverity(id: UUID, peakSeverity: MetricStatus) {
        let idStr = id.uuidString
        let peak  = peakSeverity.rawValue
        queue.async { [weak self] in
            self?._updateIncidentSeverity(id: idStr, peak: peak)
        }
    }

    // MARK: - Maintenance (fire-and-forget)

    /// Aggregates raw samples older than `rawRetentionDays` into per-minute rows,
    /// then prunes all tiers according to their configured retention windows.
    /// Call on app launch and once per hour thereafter.
    func aggregateAndPrune(rawRetentionDays: Int,
                           aggregateRetentionDays: Int,
                           incidentRetentionDays: Int) {
        let now        = Date().timeIntervalSince1970
        let rawCutoff  = now - Double(rawRetentionDays)       * 86_400
        let aggCutoff  = now - Double(aggregateRetentionDays) * 86_400
        let incCutoff  = now - Double(incidentRetentionDays)  * 86_400
        queue.async { [weak self] in
            self?._aggregate(before: rawCutoff)
            self?._exec("DELETE FROM ping_samples  WHERE timestamp < \(rawCutoff);")
            self?._exec("DELETE FROM wifi_samples  WHERE timestamp < \(rawCutoff);")
            self?._exec("DELETE FROM ping_aggregates WHERE timestamp_minute < \(aggCutoff);")
            self?._exec("DELETE FROM incidents WHERE ended_at IS NOT NULL AND ended_at < \(incCutoff);")
            self?._exec("PRAGMA wal_checkpoint(PASSIVE);")
        }
    }

    // MARK: - Queries (synchronous; call from a background context for export)

    struct PingRow {
        let timestamp: Date
        let targetID: UUID
        let rttMs: Double?
        let lossPct: Double
        let jitterMs: Double?
    }

    struct WiFiRow {
        let timestamp: Date
        let rssi: Int
        let snr: Int
        let channelNumber: Int
        let bandGHz: Double
        let txRateMbps: Double
    }

    struct IncidentRow: Identifiable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date?
        let severityRaw: Int
        let peakSeverityRaw: Int
        let cause: String

        var isActive: Bool { endedAt == nil }
    }

    /// Raw ping samples in the given time range (ascending). Pulls from `ping_samples` only;
    /// for older data use `aggregatedPingRows(for:from:to:)`.
    func pingRows(for targetID: UUID, from: Date, to: Date) -> [PingRow] {
        queue.sync { _pingRows(targetID: targetID.uuidString, from: from.timeIntervalSince1970,
                                to: to.timeIntervalSince1970) }
    }

    /// Per-minute aggregated ping rows in the given time range (ascending).
    func aggregatedPingRows(for targetID: UUID, from: Date, to: Date) -> [PingRow] {
        queue.sync { _aggRows(targetID: targetID.uuidString, from: from.timeIntervalSince1970,
                               to: to.timeIntervalSince1970) }
    }

    /// WiFi samples in the given time range (ascending).
    func wifiRows(from: Date, to: Date) -> [WiFiRow] {
        queue.sync { _wifiRows(from: from.timeIntervalSince1970, to: to.timeIntervalSince1970) }
    }

    /// Most-recent incidents, newest first. Queries both open and resolved events.
    func recentIncidents(limit: Int = 100) -> [IncidentRow] {
        queue.sync { _incidents(limit: limit) }
    }

    /// Count of raw ping samples across all targets (useful for tests and diagnostics).
    func rawPingCount() -> Int {
        queue.sync { _scalar("SELECT COUNT(*) FROM ping_samples;") }
    }

    /// Count of per-minute aggregate rows across all targets.
    func aggregateCount() -> Int {
        queue.sync { _scalar("SELECT COUNT(*) FROM ping_aggregates;") }
    }

    /// Estimated database file size in bytes (0 for in-memory databases).
    var databaseSizeBytes: Int64 {
        guard path != ":memory:" else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
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
            // Corrupted DB: wipe and reopen
            if path != ":memory:" { try? FileManager.default.removeItem(atPath: path) }
            sqlite3_open_v2(path, &db, flags, nil)
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
            CREATE INDEX IF NOT EXISTS idx_ping_target_time  ON ping_samples(target_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_wifi_time         ON wifi_samples(timestamp);
            CREATE INDEX IF NOT EXISTS idx_incidents_time    ON incidents(started_at);
            """)
    }

    // MARK: - Private: insert implementations

    private func _insertPing(ts: Double, targetID: String, label: String, host: String,
                              rtt: Double?, loss: Double, jitter: Double?) {
        let sql = """
            INSERT INTO ping_samples
                (timestamp, target_id, target_label, host, rtt_ms, loss_pct, jitter_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        guard let stmt = _prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        _bindText(stmt, 2, targetID)
        _bindText(stmt, 3, label)
        _bindText(stmt, 4, host)
        if let v = rtt    { sqlite3_bind_double(stmt, 5, v) } else { sqlite3_bind_null(stmt, 5) }
        sqlite3_bind_double(stmt, 6, loss)
        if let v = jitter { sqlite3_bind_double(stmt, 7, v) } else { sqlite3_bind_null(stmt, 7) }
        sqlite3_step(stmt)
    }

    private func _insertWiFi(ts: Double, rssi: Int, noise: Int, snr: Int,
                              channel: Int, bandGHz: Double, txRate: Double,
                              phyMode: String, iface: String,
                              ip: String?, gw: String?) {
        let sql = """
            INSERT INTO wifi_samples
                (timestamp, rssi, noise, snr, channel, band_ghz, tx_rate_mbps,
                 phy_mode, interface_name, ip_address, router_ip)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        if let v = ip { _bindText(stmt, 10, v) } else { sqlite3_bind_null(stmt, 10) }
        if let v = gw { _bindText(stmt, 11, v) } else { sqlite3_bind_null(stmt, 11) }
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
    private func _bindText(_ stmt: OpaquePointer, _ col: Int32, _ value: String) {
        sqlite3_bind_text(stmt, col, value, -1, _SQLITE_TRANSIENT)
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
