import AppKit
import SwiftUI
import MeOrThemCore

final class MetricsChartsWindowController: NSWindowController {

    init(db: SQLiteStore, targets: [PingTarget], thresholds: Thresholds) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        window.title = "Network History"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 500)
        window.center()

        super.init(window: window)

        let view = MetricsChartsView(db: db, targets: targets, thresholds: thresholds)
        window.contentViewController = NSHostingController(rootView: view)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
