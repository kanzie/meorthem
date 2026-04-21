import AppKit
import SwiftUI
@preconcurrency import MeOrThemCore

final class IncidentHistoryWindowController: NSWindowController {

    private let sqliteStore: SQLiteStore
    var onShowCharts: ((Date, Date) -> Void)?

    init(sqliteStore: SQLiteStore) {
        self.sqliteStore = sqliteStore

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Incident History"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus(onShowCharts: ((Date, Date) -> Void)? = nil) {
        self.onShowCharts = onShowCharts
        let view = IncidentHistoryView(sqliteStore: sqliteStore,
                                       onShowCharts: onShowCharts)
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
