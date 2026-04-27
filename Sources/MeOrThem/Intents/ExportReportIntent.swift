import AppIntents
import UniformTypeIdentifiers
import MeOrThemCore

/// Exports a network report for the last 24 hours to a temp file.
/// Appears in Shortcuts.app under "MeOrThem" as "Export Network Report".
struct ExportReportIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Network Report"
    static let description = IntentDescription(
        "Exports the last 24 hours of network data as a CSV or JSON file."
    )

    @Parameter(title: "Format", default: .csv)
    var format: ExportFormatOption

    enum ExportFormatOption: String, AppEnum {
        case csv  = "CSV"
        case json = "JSON"

        static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Export Format")
        static let caseDisplayRepresentations: [ExportFormatOption: DisplayRepresentation] = [
            .csv:  "CSV",
            .json: "JSON"
        ]
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        guard let env = AppEnvironment.shared else {
            throw IntentError.noEnvironment
        }
        let to   = Date()
        let from = to.addingTimeInterval(-86_400)
        let db   = env.sqliteStore
        let targets = env.settings.pingTargets

        switch format {
        case .csv:
            let csv = CSVExporter.exportFromDB(
                sqliteStore: db, targets: targets, from: from, to: to
            )
            guard let data = csv.data(using: .utf8) else {
                throw IntentError.exportFailed
            }
            let url = URL.temporaryFileURL(name: "MeOrThem-Report.csv")
            try data.write(to: url)
            let file = IntentFile(fileURL: url, filename: "MeOrThem-Report.csv",
                                  type: .commaSeparatedText)
            return .result(value: file)

        case .json:
            let data = try JSONExporter.exportFromDB(
                sqliteStore: db, targets: targets, from: from, to: to
            )
            let url = URL.temporaryFileURL(name: "MeOrThem-Report.json")
            try data.write(to: url)
            let file = IntentFile(fileURL: url, filename: "MeOrThem-Report.json",
                                  type: .json)
            return .result(value: file)
        }
    }
}

// MARK: - Errors

private enum IntentError: Error, LocalizedError {
    case noEnvironment
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noEnvironment: return "MeOrThem is not running."
        case .exportFailed:  return "Failed to generate export data."
        }
    }
}

// MARK: - URL helper

private extension URL {
    static func temporaryFileURL(name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }
}
