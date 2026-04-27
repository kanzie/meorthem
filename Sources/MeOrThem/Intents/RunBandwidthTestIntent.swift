import AppIntents

/// Triggers a bandwidth test (Ookla Speedtest) immediately.
/// Appears in Shortcuts.app under "MeOrThem" as "Run Bandwidth Test".
struct RunBandwidthTestIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Bandwidth Test"
    static var description = IntentDescription(
        "Starts a bandwidth test using the bundled Speedtest CLI. Check the MeOrThem menu for results."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let env = AppEnvironment.shared else {
            return .result(value: "MeOrThem is not running.")
        }
        guard case .idle = env.speedtestRunner.state else {
            return .result(value: "A bandwidth test is already in progress.")
        }
        env.speedtestRunner.run()
        return .result(value: "Bandwidth test started. Results will appear in the MeOrThem menu.")
    }
}
