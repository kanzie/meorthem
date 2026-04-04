import AppKit
import PDFKit
import UniformTypeIdentifiers
import os.log

private let exportLog = Logger(subsystem: "com.meorthem", category: "Export")

@MainActor
final class ExportCoordinator {
    private let store: MetricStore
    private let settings: AppSettings

    init(metricStore: MetricStore, settings: AppSettings) {
        self.store = metricStore
        self.settings = settings
    }

    func exportCSV() {
        exportLog.info("exportCSV: entry — thread=\(Thread.isMainThread ? "main" : "background")")
        let panel = makeSavePanel(name: "Me-Or-Them-Report.csv", types: [.commaSeparatedText])
        exportLog.info("exportCSV: panel created, calling showPanel")
        showPanel(panel) { [self] url in
            exportLog.info("exportCSV: panel OK, writing to \(url.path)")
            let csv = CSVExporter.export(store: self.store, targets: self.settings.pingTargets)
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                exportLog.info("exportCSV: write succeeded (\(csv.count) bytes)")
            } catch {
                exportLog.error("exportCSV: write failed — \(error.localizedDescription)")
            }
        }
    }

    func exportPDF() {
        exportLog.info("exportPDF: entry — thread=\(Thread.isMainThread ? "main" : "background")")
        let panel = makeSavePanel(name: "Me-Or-Them-Report.pdf", types: [.pdf])
        exportLog.info("exportPDF: panel created, calling showPanel")
        showPanel(panel) { [self] url in
            exportLog.info("exportPDF: panel OK, rendering PDF to \(url.path)")
            let doc = PDFExporter.export(store: self.store, targets: self.settings.pingTargets, thresholds: self.settings.thresholds)
            exportLog.info("exportPDF: PDF rendered, pageCount=\(doc.pageCount), writing")
            if doc.write(to: url) {
                exportLog.info("exportPDF: write succeeded")
            } else {
                exportLog.error("exportPDF: PDFDocument.write(to:) returned false for \(url.path)")
            }
        }
    }

    // MARK: - Private

    private func showPanel(_ panel: NSSavePanel, completion: @escaping (URL) -> Void) {
        // Prefer a sheet on the key window; fall back to mainWindow.
        // Never call runModal() from a SwiftUI button handler — that creates a nested
        // run loop inside NSHostingController and reliably crashes.
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        exportLog.info("showPanel: keyWindow=\(NSApp.keyWindow.debugDescription), mainWindow=\(NSApp.mainWindow.debugDescription), targetWindow=\(targetWindow.debugDescription)")

        if let window = targetWindow {
            exportLog.info("showPanel: using beginSheetModal on \(window)")
            panel.beginSheetModal(for: window) { response in
                exportLog.info("showPanel: sheet response=\(response.rawValue)")
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
        } else {
            // No window at all (edge case: called before any window is shown).
            // Defer to next run-loop turn so any in-flight SwiftUI layout/event
            // processing completes before we open a panel.
            exportLog.warning("showPanel: no key/main window — deferring to next run-loop turn")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                exportLog.info("showPanel(deferred): keyWindow=\(NSApp.keyWindow.debugDescription)")
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    panel.beginSheetModal(for: window) { response in
                        exportLog.info("showPanel(deferred sheet): response=\(response.rawValue)")
                        guard response == .OK, let url = panel.url else { return }
                        completion(url)
                    }
                } else {
                    exportLog.warning("showPanel(deferred): still no window — aborting export")
                }
            }
        }
    }

    private func makeSavePanel(name: String, types: [UTType]) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.isExtensionHidden = false
        return panel
    }
}
