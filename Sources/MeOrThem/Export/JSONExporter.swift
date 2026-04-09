import Foundation
import MeOrThemCore

@MainActor
enum JSONExporter {

    // MARK: - SQLite-backed export

    static func exportFromDB(sqliteStore: SQLiteStore, targets: [PingTarget], rawDays: Int) throws -> Data {
        let now  = Date()
        let from = now.addingTimeInterval(-Double(rawDays) * 86400)

        var targetsJSON: [[String: Any]] = []
        for target in targets {
            let rows = sqliteStore.pingRows(for: target.id, from: from, to: now)
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

        var wifiJSON: [[String: Any]] = []
        for w in sqliteStore.wifiRows(from: from, to: now) {
            wifiJSON.append([
                "timestamp":      iso.string(from: w.timestamp),
                "rssi":           w.rssi,
                "snr":            w.snr,
                "channelNumber":  w.channelNumber,
                "channelBandGHz": w.bandGHz,
                "txRateMbps":     w.txRateMbps,
            ])
        }

        let root: [String: Any] = [
            "exportedAt": iso.string(from: now),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "targets":    targetsJSON,
            "wifi":       wifiJSON,
        ]

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    static func export(store: MetricStore, targets: [PingTarget]) throws -> Data {
        var targetsJSON: [[String: Any]] = []

        for target in targets {
            let history = store.pingHistory[target.id]?.toArray() ?? []
            let records: [[String: Any]] = history.map { r in
                var rec: [String: Any] = [
                    "timestamp":    iso.string(from: r.timestamp),
                    "lossPercent":  r.lossPercent,
                ]
                if let rtt    = r.rtt    { rec["rttMs"]    = rtt }
                if let jitter = r.jitter { rec["jitterMs"] = jitter }
                return rec
            }
            targetsJSON.append([
                "id":      target.id.uuidString,
                "label":   target.label,
                "host":    target.host,
                "records": records,
            ])
        }

        var wifiJSON: [[String: Any]] = []
        for w in store.wifiHistory.toArray() {
            var entry: [String: Any] = [
                "timestamp":       iso.string(from: w.timestamp),
                "rssi":            w.rssi,
                "noise":           w.noise,
                "snr":             w.snr,
                "channelNumber":   w.channelNumber,
                "channelBandGHz":  w.channelBandGHz,
                "txRateMbps":      w.txRateMbps,
                "phyMode":         w.phyMode,
                "interfaceName":   w.interfaceName,
            ]
            if let ip = w.ipAddress  { entry["ipAddress"] = ip }
            if let gw = w.routerIP   { entry["routerIP"]  = gw }
            wifiJSON.append(entry)
        }

        let root: [String: Any] = [
            "exportedAt": iso.string(from: Date()),
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "targets":    targetsJSON,
            "wifi":       wifiJSON,
        ]

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static let iso = ISO8601DateFormatter()
}
