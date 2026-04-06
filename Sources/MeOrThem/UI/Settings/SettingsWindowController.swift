import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {

    convenience init(settings: AppSettings) {
        let rootView = SettingsView()
            .environmentObject(settings)

        let vc = NSHostingController(rootView: rootView)
        vc.sizingOptions = .preferredContentSize

        let window = NSWindow(contentViewController: vc)
        window.title = "Me Or Them Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 660, height: 540))
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
    }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
