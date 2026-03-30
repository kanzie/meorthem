import Foundation

enum SpeedtestParser {
    enum Error: Swift.Error, LocalizedError {
        case invalidJSON(String)
        case missingField(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let s):  return "Speedtest: invalid JSON — \(s)"
            case .missingField(let f): return "Speedtest: missing field '\(f)'"
            }
        }
    }

    /// Parses Ookla speedtest CLI JSON output (--format=json).
    static func parse(_ json: String) throws -> SpeedtestResult {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidJSON(json.prefix(200).string)
        }

        guard let dl = (obj["download"] as? [String: Any])?["bandwidth"] as? Double,
              let ul = (obj["upload"]   as? [String: Any])?["bandwidth"] as? Double else {
            throw Error.missingField("download/upload bandwidth")
        }

        let pingObj  = obj["ping"] as? [String: Any]
        let latency  = pingObj?["latency"] as? Double ?? 0
        let jitter   = pingObj?["jitter"]  as? Double ?? 0
        let isp      = obj["isp"] as? String ?? "Unknown"
        let server   = (obj["server"] as? [String: Any])?["name"] as? String ?? "Unknown"

        return SpeedtestResult(
            downloadMbps: dl / 125_000,   // bytes/s → Mbps  (÷ 125000 = ÷1000000 × 8)
            uploadMbps:   ul / 125_000,
            latencyMs:    latency,
            jitterMs:     jitter,
            isp:          isp,
            serverName:   server,
            timestamp:    Date()
        )
    }
}

private extension Substring {
    var string: String { String(self) }
}
