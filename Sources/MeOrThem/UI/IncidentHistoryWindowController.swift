import AppKit
import SwiftUI
@preconcurrency import MeOrThemCore

final class IncidentHistoryWindowController: NSWindowController {

    private let sqliteStore: SQLiteStore

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

    func showAndFocus() {
        let view = IncidentHistoryView(sqliteStore: sqliteStore)
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
