import AppKit
import SwiftUI

final class PingReportWindowController: NSWindowController {

    private let store:          MetricStore
    private let settings:       AppSettings
    private let exporter:       ExportCoordinator
    var onShowCharts: (() -> Void)?

    init(store: MetricStore, settings: AppSettings, exporter: ExportCoordinator,
         onShowCharts: (() -> Void)? = nil) {
        self.store        = store
        self.settings     = settings
        self.exporter     = exporter
        self.onShowCharts = onShowCharts

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ping Report"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        let reportText = store.summaryText(targets: settings.pingTargets)
        let view = PingReportView(reportText: reportText, exporter: exporter,
                                  onShowCharts: onShowCharts)
        let vc = NSHostingController(rootView: view)
        window?.contentViewController = vc
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PingReportView: View {
    let reportText:   String
    let exporter:     ExportCoordinator
    var onShowCharts: (() -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(reportText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            HStack(spacing: 8) {
                Button("Export CSV")  { exporter.exportCSV() }
                Button("Export PDF")  { exporter.exportPDF() }
                Button("Export JSON") { exporter.exportJSON() }
                if let showCharts = onShowCharts {
                    Button("View Charts") { showCharts() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button(copied ? "Copied!" : "Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 350)
    }
}
