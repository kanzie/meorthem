import AppIntents

/// Returns details about the most recent recorded network incident.
/// Appears in Shortcuts.app under "MeOrThem" as "Get Last Incident".
struct GetLastIncidentIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Incident"
    static var description = IntentDescription(
        "Returns the time, duration, and cause of the most recent network incident."
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let env = AppEnvironment.shared else {
            return .result(value: "MeOrThem is not running.")
        }
        let rows = env.sqliteStore.allIncidentRows(limit: 1)
        guard let row = rows.first else {
            return .result(value: "No incidents recorded.")
        }

        let relFmt = RelativeDateTimeFormatter()
        relFmt.unitsStyle = .full
        let ago = relFmt.localizedString(for: row.startedAt, relativeTo: Date())

        let durationText: String
        if let ended = row.endedAt {
            let secs = Int(ended.timeIntervalSince(row.startedAt))
            if secs < 60 {
                durationText = "\(secs)s"
            } else {
                durationText = "\(secs / 60)m \(secs % 60)s"
            }
        } else {
            durationText = "ongoing"
        }

        return .result(value: "Last incident: \(ago) · duration \(durationText) · cause: \(row.cause)")
    }
}
