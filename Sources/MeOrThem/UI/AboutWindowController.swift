import AppKit
import SwiftUI

final class AboutWindowController: NSWindowController {

    static let shared = AboutWindowController()

    private init() {
        let rootView = AboutView()
        let vc = NSHostingController(rootView: rootView)
        vc.sizingOptions = .preferredContentSize

        let window = NSWindow(contentViewController: vc)
        window.title = "About MeOrThem"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)

            Text("MeOrThem")
                .font(.system(size: 24, weight: .bold))

            Text("Version \(version)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Network Quality Monitor")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()
                .padding(.vertical, 4)

            Text("Developed by Christian \u{201C}Kanzie\u{201D} Nilsson")
                .font(.body)

            Spacer().frame(height: 4)

            Text("Distributed under the MIT License")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Copyright \u{00A9} 2025 Christian Nilsson")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(32)
        .frame(width: 340)
    }
}
