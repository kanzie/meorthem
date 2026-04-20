import Foundation
import MeOrThemCore

@MainActor
enum JSONExporter {

    // MARK: - SQLite-backed export (date range aware)

    static func exportFromDB(sqliteStore: SQLiteStore, targets: [PingTarget],
                             from: Date, to: Date) throws -> Data {
        var targetsJSON: [[String: Any]] = []
        for target in targets {
            let rows = sqliteStore.pingRows(for: target.id, from: from, to: to)
            let records: [[String: Any]] = rows.map { r in
                var rec: [String: Any] = [
                    "timestamp":   iso.string(from: r.timestamp),
                    "lossPercent": r.lossPct,
                ]
                if let rtt    = r.rttMs    { rec["rttMs"]    = rtt }
                if let jitter = r.jitterMs { rec["jitterMs"] = jitter }
                return rec
            }
            targetsJSON.append([
                "id":      target.id.uuidString,
                "label":   target.label,
                "host":    target.host,
                "records": records,
            ])
        }

        let speedtestJSON: [[String: Any]] = sqliteStore.speedtestRows(from: from, to: to).map { s in
            [
                "timestamp":    iso.string(from: s.timestamp),
                "downloadMbps": s.downloadMbps,
                "uploadMbps":   s.uploadMbps,
                "latencyMs":    s.latencyMs,
                "jitterMs":     s.jitterMs,
                "isp":          s.isp,
                "serverName":   s.serverName,
            ]
        }

        var wifiJSON: [[String: Any]] = []
        for w in sqliteStore.wifiRows(from: from, to: to) {
            wifiJSON.append([
                "timestamp":      iso.string(from: w.timestamp),
                "rssi":           w.rssi,
                "snr":            w.snr,
                "channelNumber":  w.channelNumber,
                "channelBandGHz": w.bandGHz,
                "txRateMbps":     w.txRateMbps,
            ])
        }

        // Group DNS resolver rows by IP for per-resolver summary + raw samples
        let dnsRawRows = sqliteStore.dnsResolverRows(from: from, to: to)
        var byResolverIP: [String: [SQLiteStore.DNSResolverRow]] = [:]
        for row in dnsRawRows { byResolverIP[row.resolverIP, default: []].append(row) }
        let dnsResolversJSON: [[String: Any]] = byResolverIP
            .sorted { $0.key < $1.key }
            .map { (ip, rows) in
                let name     = rows.first?.resolverName ?? ip
                let rtts     = rows.compactMap(\.resolveMs)
                let failRate = rows.isEmpty ? 0.0
                                           : Double(rows.filter { $0.resolveMs == nil }.count) / Double(rows.count)
                let samples: [[String: Any]] = rows.map { r in
                    var s: [String: Any] = ["timestamp": iso.string(from: r.timestamp)]
                    if let ms = r.resolveMs { s["resolveMs"] = ms }
                    if let rc = r.rcode     { s["rcode"]     = rc }
                    return s
                }
                var obj: [String: Any] = [
                    "name":        name,
                    "ip":          ip,
                    "failureRate": failRate,
                    "sampleCount": rows.count,
                    "samples":     samples,
                ]
                if let tm = trimmedMean(rtts) { obj["trimmedMeanMs"] = tm }
                return obj
            }

        let sessionsJSON: [[String: Any]] = sqliteStore.sessionsInRange(from: from, to: to).map { s in
            var obj: [String: Any] = [
                "id":             s.id.uuidString,
                "displayName":    s.displayName,
                "connectionType": s.connectionType,
                "startedAt":      iso.string(from: s.startedAt),
                "lastSeen":       iso.string(from: s.lastSeen),
            ]
            if s.weakFingerprint {
                obj["weakFingerprintWarning"] = "Ethernet session without router hardware address — " +
                    "may contain data from multiple networks with the same gateway IP and subnet."
            }
            return obj
        }

        let root: [String: Any] = [
            "exportedAt":     iso.string(from: Date()),
            "periodFrom":     iso.string(from: from),
            "periodTo":       iso.string(from: to),
            "appVersion":     Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "sessions":       sessionsJSON,
            "targets":        targetsJSON,
            "bandwidthTests": speedtestJSON,
            "wifi":           wifiJSON,
            "dnsResolvers":   dnsResolversJSON,
        ]

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Helpers

    /// Drop bottom+top 10% (min 1 each when ≥4 samples) then average.
    private static func trimmedMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count >= 4 else { return sorted.reduce(0, +) / Double(sorted.count) }
        let drop    = max(1, sorted.count / 10)
        let trimmed = Array(sorted.dropFirst(drop).dropLast(drop))
        return trimmed.isEmpty ? nil : trimmed.reduce(0, +) / Double(trimmed.count)
    }

    private static let iso = ISO8601DateFormatter()
}
