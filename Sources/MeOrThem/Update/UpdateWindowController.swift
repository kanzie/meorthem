import AppKit
import Darwin
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
        win.setContentSize(NSSize(width: 500, height: 520))
        win.minSize = NSSize(width: 420, height: 380)
        win.maxSize = NSSize(width: 560, height: 800)
        win.center()
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Returns true only for https:// URLs hosted on github.com or the GitHub
    /// release asset CDN (objects.githubusercontent.com). Rejects any URL that
    /// an MITM or compromised update channel might inject.
    static func isAllowedReleaseURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              let host = url.host else { return false }
        let allowed = ["github.com", "objects.githubusercontent.com",
                       "codeload.github.com", "releases.githubusercontent.com"]
        return allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    /// Sets the com.apple.quarantine xattr on the file, marking it as
    /// internet-downloaded so Gatekeeper performs its notarisation check.
    /// Format mirrors what Safari writes: flags;hex_mac_epoch;bundle_id;UUID
    /// macOS epoch starts 2001-01-01 (978307200 seconds after Unix epoch).
    static func stampQuarantine(at url: URL) {
        let macEpoch: TimeInterval = 978307200
        let ts = UInt32(max(0, Date().timeIntervalSince1970 - macEpoch))
        let uuid = UUID().uuidString
        let value = String(format: "0083;%08x;com.meorthem.app;%@", ts, uuid)
        value.withCString { ptr in
            _ = setxattr(url.path, "com.apple.quarantine", ptr, strlen(ptr), 0, 0)
        }
    }
}

// MARK: - UpdateView

private struct UpdateView: View {
    let release: GitHubRelease
    let currentVersion: String
    let onDismiss: () -> Void

    @State private var isDownloading    = false
    @State private var downloadError: String?
    @State private var changelog: String?
    @State private var changelogLoading = true

    // Raw content URL for CHANGELOG.md on GitHub
    private let changelogURL = URL(string: "https://raw.githubusercontent.com/kanzie/meorthem/main/CHANGELOG.md")!

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: Header
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

            // MARK: Changelog
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What's changed")
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)

                    if changelogLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    } else {
                        Text(changelog ?? release.body ?? "No release notes available.")
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .frame(minHeight: 160, maxHeight: 300)

            Divider()

            // MARK: Install instructions
            VStack(alignment: .leading, spacing: 4) {
                Text("How to install:")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                Text("1. Quit Me Or Them before installing.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("2. Open the DMG and drag Me Or Them to Applications.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("3. Click Replace when asked, then relaunch.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if let err = downloadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            // MARK: Buttons
            HStack {
                Button("Skip This Version") {
                    UpdateChecker.skipVersion(release.tagName)
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Later") { onDismiss() }

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
        .frame(minWidth: 420)
        .task { await fetchChangelog() }
    }

    // MARK: - Changelog fetch

    private func fetchChangelog() async {
        changelogLoading = true
        if let (data, _) = try? await URLSession.shared.data(from: changelogURL),
           let text = String(data: data, encoding: .utf8) {
            changelog = wordWrap(extractDelta(from: text))
        }
        changelogLoading = false
    }

    /// Extracts changelog sections for every version strictly newer than
    /// `currentVersion` and at most `release.version`, in document order.
    /// Falls back to the full file if parsing finds nothing.
    private func extractDelta(from text: String) -> String {
        // Split on version headings ("## v2.0.3 — …").
        // Each element after the first is one release block.
        let headingRegex = try? NSRegularExpression(pattern: #"^## (v\d+\.\d+\.\d+)"#)
        var sections: [(version: String, body: String)] = []
        var current: (version: String, lines: [String])?

        for line in text.components(separatedBy: "\n") {
            let range = NSRange(line.startIndex..., in: line)
            if let m = headingRegex?.firstMatch(in: line, range: range),
               let vRange = Range(m.range(at: 1), in: line) {
                if let prev = current {
                    sections.append((prev.version, prev.lines.joined(separator: "\n")))
                }
                current = (String(line[vRange]), [line])
            } else {
                current?.lines.append(line)
            }
        }
        if let last = current {
            sections.append((last.version, last.lines.joined(separator: "\n")))
        }

        let delta = sections.filter { section in
            versionIsNewer(section.version, than: "v\(currentVersion)") &&
            !versionIsNewer(section.version, than: release.version)
        }

        guard !delta.isEmpty else { return text }
        return delta.map(\.body)
                    .joined(separator: "\n\n---\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns true when `a` is strictly newer than `b` (both "vX.Y.Z" strings).
    private func versionIsNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.drop(while: { $0 == "v" })
             .split(separator: ".")
             .compactMap { Int($0) }
        }
        let lhs = parts(a), rhs = parts(b)
        for (l, r) in zip(lhs, rhs) {
            if l != r { return l > r }
        }
        return lhs.count > rhs.count
    }

    /// Word-wraps each line of `text` at `width` characters, preserving
    /// blank lines and indentation so markdown structure stays readable.
    private func wordWrap(_ text: String, at width: Int = 80) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            guard line.count > width else { return line }
            // Preserve leading whitespace (e.g. indented list items).
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            var result: [String] = []
            var current = indent
            for word in line.dropFirst(indent.count).components(separatedBy: " ") {
                if current == indent {
                    current += word
                } else if current.count + 1 + word.count <= width {
                    current += " " + word
                } else {
                    result.append(current)
                    current = indent + word
                }
            }
            if !current.isEmpty { result.append(current) }
            return result.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - Download & install

    private func downloadAndInstall() {
        guard let urlStr = release.dmgURL,
              let url = URL(string: urlStr),
              UpdateWindowController.isAllowedReleaseURL(url) else {
            downloadError = "Update URL is invalid or not from a trusted host."
            return
        }
        isDownloading = true
        downloadError = nil

        Task { @MainActor in
            do {
                let (localURL, _) = try await URLSession.shared.download(from: url)
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: localURL, to: dest)
                // Stamp the quarantine extended attribute so macOS Gatekeeper checks
                // notarisation and code signature before the DMG can mount/run.
                // Without this, files fetched via URLSession have no quarantine flag
                // and bypass Gatekeeper entirely (unlike Safari downloads).
                UpdateWindowController.stampQuarantine(at: dest)
                NSWorkspace.shared.open(dest)
                // Brief pause so Finder has time to initiate the DMG mount
                // before this process exits.
                try? await Task.sleep(nanoseconds: 500_000_000)
                onDismiss()
                NSApp.terminate(nil)
            } catch {
                downloadError = "Download failed: \(error.localizedDescription)"
                isDownloading = false
            }
        }
    }

}
