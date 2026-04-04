import Foundation

@MainActor
enum JSONExporter {

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
                "ssid":            w.ssid,
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
