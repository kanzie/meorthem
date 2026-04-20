import Foundation
import MeOrThemCore

@MainActor
enum CSVExporter {
    private static let isoFormatter = ISO8601DateFormatter()

    // MARK: - SQLite-backed export (date range aware)

    static func exportFromDB(sqliteStore: SQLiteStore, targets: [PingTarget],
                             from: Date, to: Date) -> String {
        var lines = [String]()

        lines.append("# Me Or Them Ping Report — \(isoFormatter.string(from: Date()))")
        lines.append("# Period: \(isoFormatter.string(from: from)) — \(isoFormatter.string(from: to))")

        let sessions = sqliteStore.sessionsInRange(from: from, to: to)
        if !sessions.isEmpty {
            let summary = sessions.map { "\($0.displayName) (\($0.connectionType))" }.joined(separator: ", ")
            lines.append("# Sessions: \(summary)")
        }
        lines.append("")

        // ── Ping samples ───────────────────────────────────────────────────
        lines.append("Timestamp,Target,Host,RTT_ms,Loss_pct,Jitter_ms")
        for target in targets {
            let rows = sqliteStore.pingRows(for: target.id, from: from, to: to)
            for r in rows {
                let ts     = isoFormatter.string(from: r.timestamp)
                let rtt    = r.rttMs.map { String(format: "%.3f", $0) } ?? ""
                let loss   = String(format: "%.1f", r.lossPct)
                let jitter = r.jitterMs.map { String(format: "%.3f", $0) } ?? ""
                lines.append("\(ts),\(csvQuote(target.label)),\(csvQuote(target.host)),\(rtt),\(loss),\(jitter)")
            }
        }

        // ── Bandwidth tests ────────────────────────────────────────────────
        lines.append("")
        lines.append("# Bandwidth Tests")
        lines.append("Timestamp,Download_Mbps,Upload_Mbps,Latency_ms,Jitter_ms,ISP,Server")
        let speedRows = sqliteStore.speedtestRows(from: from, to: to)
        for s in speedRows {
            let ts = isoFormatter.string(from: s.timestamp)
            lines.append("\(ts),\(String(format: "%.2f", s.downloadMbps)),\(String(format: "%.2f", s.uploadMbps)),\(String(format: "%.2f", s.latencyMs)),\(String(format: "%.2f", s.jitterMs)),\(csvQuote(s.isp)),\(csvQuote(s.serverName))")
        }

        // ── Wi-Fi history ──────────────────────────────────────────────────
        let wifiRows = sqliteStore.wifiRows(from: from, to: to)
        if !wifiRows.isEmpty {
            lines.append("")
            lines.append("# Wi-Fi History")
            lines.append("Timestamp,RSSI_dBm,SNR_dB,Channel,Band_GHz,TxRate_Mbps")
            for w in wifiRows {
                let ts = isoFormatter.string(from: w.timestamp)
                lines.append("\(ts),\(w.rssi),\(w.snr),\(w.channelNumber),\(String(format:"%.1f",w.bandGHz)),\(String(format:"%.0f",w.txRateMbps))")
            }
        } else {
            lines.append("")
            lines.append("# Wi-Fi History")
            lines.append("# No Wi-Fi data in this period (Ethernet or VPN connection)")
        }

        // ── DNS resolver samples ───────────────────────────────────────────
        lines.append("")
        lines.append("# DNS Resolver Samples")
        lines.append("Timestamp,Resolver_Name,Resolver_IP,Resolve_ms,RCODE")
        let dnsRows = sqliteStore.dnsResolverRows(from: from, to: to)
        for d in dnsRows {
            let ts = isoFormatter.string(from: d.timestamp)
            let ms = d.resolveMs.map { String(format: "%.3f", $0) } ?? ""
            let rc = d.rcode.map { String($0) } ?? ""
            lines.append("\(ts),\(csvQuote(d.resolverName)),\(csvQuote(d.resolverIP)),\(ms),\(rc)")
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
