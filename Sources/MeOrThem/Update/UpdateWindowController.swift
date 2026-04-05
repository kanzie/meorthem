import AppKit
import SwiftUI

@MainActor
final class UpdateWindowController: NSWindowController {

    static let shared = UpdateWindowController()

    private var hostingController: NSHostingController<UpdateView>?

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(release: GitHubRelease, currentVersion: String) {
        let view = UpdateView(release: release, currentVersion: currentVersion) { [weak self] in
            self?.window?.close()
        }

        if let hc = hostingController {
            hc.rootView = view
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hc = NSHostingController(rootView: view)
        hc.sizingOptions = .preferredContentSize
        hostingController = hc

        let win = NSWindow(contentViewController: hc)
        win.title = "Update Available"
        win.styleMask = [.titled, .closable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 480, height: 400))
        win.minSize = NSSize(width: 380, height: 300)
        win.center()
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - UpdateView

private struct UpdateView: View {
    let release: GitHubRelease
    let currentVersion: String
    let onDismiss: () -> Void

    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 14) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of Me Or Them is available!")
                        .font(.headline)
                    Text("Me Or Them \(release.version) is now available — you have \(currentVersion).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            // Changelog
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's new in \(release.version)")
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                    Text(release.body ?? "No release notes available.")
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .frame(minHeight: 140, maxHeight: 280)

            Divider()

            if let err = downloadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }

            // Buttons
            HStack {
                Button("Skip This Version") {
                    UpdateChecker.skipVersion(release.tagName)
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Later") {
                    onDismiss()
                }

                if release.dmgURL != nil {
                    Button(isDownloading ? "Downloading…" : "Download & Install") {
                        downloadAndInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 380)
    }

    private func downloadAndInstall() {
        guard let urlStr = release.dmgURL, let url = URL(string: urlStr) else { return }
        isDownloading = true
        downloadError = nil

        Task {
            do {
                let (localURL, _) = try await URLSession.shared.download(from: url)
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                // Overwrite if exists
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: localURL, to: dest)
                NSWorkspace.shared.open(dest)
                onDismiss()
            } catch {
                downloadError = "Download failed: \(error.localizedDescription)"
                isDownloading = false
            }
        }
    }
}
