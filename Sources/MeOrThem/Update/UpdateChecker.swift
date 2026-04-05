import AppKit
import Foundation

// MARK: - Model

struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    /// Version string stripped of leading "v".
    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

    /// First .dmg asset download URL, if any.
    var dmgURL: String? { assets.first(where: { $0.name.hasSuffix(".dmg") })?.browserDownloadURL }
}

// MARK: - UpdateChecker

@MainActor
final class UpdateChecker {

    static let shared = UpdateChecker()

    private let apiURL = URL(string: "https://api.github.com/repos/kanzie/meorthem/releases/latest")!
    private let checkIntervalSeconds: TimeInterval = 24 * 3600
    private var timer: Timer?

    private enum UDKey {
        static let lastCheck    = "updateChecker.lastCheckDate"
        static let skippedTag   = "updateChecker.skippedTag"
    }

    private init() {}

    // MARK: - Public API

    /// Call once on startup. Checks immediately if 24 h have passed, then schedules periodic checks.
    func startPeriodicChecks() {
        scheduleTimer()
        checkIfDue()
    }

    /// Manual trigger from Settings — always performs the check and surfaces "already up to date" feedback.
    func checkManually() {
        Task { await fetchAndEvaluate(manual: true) }
    }

    // MARK: - Internal

    private func scheduleTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchAndEvaluate(manual: false)
            }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: UDKey.lastCheck) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= checkIntervalSeconds {
            Task { await fetchAndEvaluate(manual: false) }
        }
    }

    private func fetchAndEvaluate(manual: Bool) async {
        UserDefaults.standard.set(Date(), forKey: UDKey.lastCheck)

        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        else {
            if manual { showAlreadyUpToDate(current: currentVersion()) }
            return
        }

        let current  = currentVersion()
        let latest   = release.version
        let skipped  = UserDefaults.standard.string(forKey: UDKey.skippedTag)

        guard isNewer(latest, than: current) else {
            if manual {
                showAlreadyUpToDate(current: current)
            }
            return
        }

        // User already chose to skip this exact version
        if !manual && skipped == release.tagName {
            return
        }

        // No DMG available — silent stop
        guard release.dmgURL != nil else {
            if manual {
                showAlreadyUpToDate(current: current)
            }
            return
        }

        UpdateWindowController.shared.show(release: release, currentVersion: current)
    }

    // MARK: - Helpers

    private func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Returns true if `candidate` is strictly newer than `base` using semver-style comparison.
    private func isNewer(_ candidate: String, than base: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(base)
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private func components(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }

    private func showAlreadyUpToDate(current: String) {
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Me Or Them \(current) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Skip

    static func skipVersion(_ tagName: String) {
        UserDefaults.standard.set(tagName, forKey: UDKey.skippedTag)
    }
}
