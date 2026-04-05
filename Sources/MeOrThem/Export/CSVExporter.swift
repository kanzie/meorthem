import Foundation

@MainActor
enum CSVExporter {
    private static let isoFormatter = ISO8601DateFormatter()

    static func export(store: MetricStore, targets: [PingTarget]) -> String {
        var lines = [String]()

        // Ping section
        lines.append("# Me Or Them Ping Report — \(isoFormatter.string(from: Date()))")
        lines.append("Timestamp,Host,Label,RTT_ms,Loss_pct,Jitter_ms")

        for target in targets {
            let history = store.pingHistory[target.id]?.toArray() ?? []
            for r in history {
                let ts     = isoFormatter.string(from: r.timestamp)
                let rtt    = r.rtt.map { String(format: "%.3f", $0) } ?? ""
                let loss   = String(format: "%.1f", r.lossPercent)
                let jitter = r.jitter.map { String(format: "%.3f", $0) } ?? ""
                lines.append("\(ts),\(csvQuote(target.host)),\(csvQuote(target.label)),\(rtt),\(loss),\(jitter)")
            }
        }

        // WiFi section
        lines.append("")
        lines.append("# Wi-Fi History")
        lines.append("Timestamp,SSID,RSSI_dBm,SNR_dB,Channel,Band_GHz,TxRate_Mbps")

        let wifiHistory = store.wifiHistory.toArray()
        for w in wifiHistory {
            let ts = isoFormatter.string(from: w.timestamp)
            lines.append("\(ts),\(csvQuote(w.ssid)),\(w.rssi),\(w.snr),\(w.channelNumber),\(String(format:"%.1f",w.channelBandGHz)),\(String(format:"%.0f",w.txRateMbps))")
        }

        return lines.joined(separator: "\n")
    }

    /// RFC 4180 quoting: wraps field in quotes if it contains comma, quote, or newline;
    /// internal quotes are escaped as "".
    private static func csvQuote(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
