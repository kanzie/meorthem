import AppKit
import PDFKit

@MainActor
final class ExportCoordinator {
    private let store: MetricStore
    private let settings: AppSettings

    init(metricStore: MetricStore, settings: AppSettings) {
        self.store = metricStore
        self.settings = settings
    }

    func exportCSV() {
        let panel = makeSavePanel(name: "MeOrThem-Report.csv", types: ["public.comma-separated-values-text", "csv"])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = CSVExporter.export(store: store, targets: settings.pingTargets)
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }

    func exportPDF() {
        let panel = makeSavePanel(name: "MeOrThem-Report.pdf", types: ["com.adobe.pdf"])
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let doc = PDFExporter.export(store: store, targets: settings.pingTargets)
        doc.write(to: url)
    }

    // MARK: - Private

    private func makeSavePanel(name: String, types: [String]) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types.compactMap { UTType($0) }
        panel.isExtensionHidden = false
        return panel
    }
}

import UniformTypeIdentifiers
private extension UTType {
    init?(_ string: String) {
        if let t = UTType(mimeType: string) { self = t; return }
        if let t = UTType(tag: string, tagClass: .filenameExtension, conformingTo: nil) { self = t; return }
        if let t = UTType(string) as UTType? { self = t; return }
        return nil
    }
}
