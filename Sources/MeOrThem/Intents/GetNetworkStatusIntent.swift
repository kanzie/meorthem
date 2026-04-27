import AppIntents

/// Returns the current network connection quality and average latency.
/// Appears in Shortcuts.app under "MeOrThem" as "Get Network Status".
struct GetNetworkStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Network Status"
    static var description = IntentDescription(
        "Returns the current connection quality (Good / Degraded / Poor) and average latency."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let env = AppEnvironment.shared else {
            return .result(value: "MeOrThem is not running.")
        }
        let store  = env.metricStore
        let status = store.overallStatus.label

        // Average RTT across all active external targets (excluding gateway)
        let rtts = store.latestPing
            .filter { $0.key != PingTarget.gatewayID }
            .values
            .compactMap { $0.rtt }
        let latencyText: String
        if rtts.isEmpty {
            latencyText = "N/A"
        } else {
            let avg = rtts.reduce(0, +) / Double(rtts.count)
            latencyText = String(format: "%.0f ms", avg)
        }

        let isp = store.currentSessionISPName.map { " · \($0)" } ?? ""
        return .result(value: "Status: \(status)\(isp) · Avg Latency: \(latencyText)")
    }
}
