import Foundation
import MeOrThemCore
import Network

/// A minimal local HTTP server that serves current network metrics in Prometheus text format
/// (`GET /metrics`) and JSON (`GET /metrics.json`) on localhost only.
///
/// Uses NWListener (Network.framework) — no entitlements needed for loopback binding.
/// One connection at a time, no keep-alive. All metric reads are on the @MainActor.
@MainActor
final class MetricsHTTPServer {

    private var listener: NWListener?
    private weak var metricStore: MetricStore?
    private weak var settings: AppSettings?

    init(metricStore: MetricStore, settings: AppSettings) {
        self.metricStore = metricStore
        self.settings    = settings
    }

    // MARK: - Start / Stop

    func start(port: Int) throws {
        stop()
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(clamping: port))
        let params = NWParameters.tcp
        // Bind to localhost only — never expose to the network.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                self.handleConnection(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state { }   // silently swallow bind failures
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { connection.cancel(); return }
            let requestLine = String(data: data, encoding: .utf8)?
                .components(separatedBy: "\r\n").first ?? ""
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                let path = self.parsePath(from: requestLine)
                let (body, contentType) = self.responseBody(for: path)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                let response = (header + body).data(using: .utf8) ?? Data()
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func parsePath(from requestLine: String) -> String {
        // e.g. "GET /metrics HTTP/1.1" → "/metrics"
        let parts = requestLine.components(separatedBy: " ")
        return parts.count >= 2 ? parts[1] : "/"
    }

    private func responseBody(for path: String) -> (body: String, contentType: String) {
        switch path {
        case "/metrics":
            return (prometheusResponse(), "text/plain; version=0.0.4; charset=utf-8")
        case "/metrics.json":
            return (jsonResponse(), "application/json; charset=utf-8")
        default:
            return ("# GET /metrics or /metrics.json\n",
                    "text/plain; charset=utf-8")
        }
    }

    // MARK: - Prometheus format

    func prometheusResponse() -> String {
        guard let store = metricStore, let settings = settings else { return "" }
        var lines: [String] = []

        // Overall status (0=green, 1=yellow, 2=red)
        let statusInt: Int
        switch store.overallStatus {
        case .green:  statusInt = 0
        case .yellow: statusInt = 1
        case .red:    statusInt = 2
        }
        lines.append("# HELP meorthem_overall_status Connection quality (0=green 1=yellow 2=red)")
        lines.append("# TYPE meorthem_overall_status gauge")
        lines.append("meorthem_overall_status \(statusInt)")

        // Per-target latency, loss, jitter
        lines.append("# HELP meorthem_latency_ms Average RTT in milliseconds")
        lines.append("# TYPE meorthem_latency_ms gauge")
        lines.append("# HELP meorthem_loss_percent Packet loss percentage")
        lines.append("# TYPE meorthem_loss_percent gauge")
        lines.append("# HELP meorthem_jitter_ms Jitter in milliseconds")
        lines.append("# TYPE meorthem_jitter_ms gauge")

        for target in settings.pingTargets {
            let label = prometheusLabel(target.label)
            if let ping = store.latestPing[target.id] {
                if let rtt = ping.rtt {
                    lines.append(String(format: "meorthem_latency_ms{target=\"%@\"} %.2f", label, rtt))
                }
                lines.append(String(format: "meorthem_loss_percent{target=\"%@\"} %.1f", label, ping.lossPercent))
                if let jitter = ping.jitter {
                    lines.append(String(format: "meorthem_jitter_ms{target=\"%@\"} %.2f", label, jitter))
                }
            }
        }

        // WiFi RSSI
        if let wifi = store.latestWifi {
            lines.append("# HELP meorthem_wifi_rssi_dbm WiFi signal strength in dBm")
            lines.append("# TYPE meorthem_wifi_rssi_dbm gauge")
            lines.append("meorthem_wifi_rssi_dbm \(wifi.rssi)")
        }

        // DNS resolver latencies
        if let dns = store.dnsSummary, dns.bestRTTMs > 0 {
            lines.append("# HELP meorthem_dns_latency_ms DNS resolution latency in milliseconds")
            lines.append("# TYPE meorthem_dns_latency_ms gauge")
            lines.append(String(format: "meorthem_dns_latency_ms{resolver=\"%@\"} %.2f",
                                prometheusLabel(dns.bestResolverName), dns.bestRTTMs))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON format

    func jsonResponse() -> String {
        guard let store = metricStore, let settings = settings else { return "{}" }
        var targets: [[String: Any]] = []

        for target in settings.pingTargets {
            var entry: [String: Any] = ["label": target.label, "host": target.host]
            if let ping = store.latestPing[target.id] {
                entry["latency_ms"]    = ping.rtt as Any
                entry["loss_percent"]  = ping.lossPercent
                entry["jitter_ms"]     = ping.jitter as Any
            }
            targets.append(entry)
        }

        var root: [String: Any] = [
            "overall_status": store.overallStatus.rawValue,
            "targets":        targets
        ]
        if let wifi = store.latestWifi {
            root["wifi_rssi_dbm"] = wifi.rssi
        }
        if let dns = store.dnsSummary, dns.bestRTTMs > 0 {
            root["dns_latency_ms"]  = dns.bestRTTMs
            root["dns_resolver"]    = dns.bestResolverName
        }

        guard let data = try? JSONSerialization.data(withJSONObject: root,
                                                     options: .prettyPrinted),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    // MARK: - Helpers

    /// Escapes a label value for Prometheus exposition format.
    private func prometheusLabel(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}
