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
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    private let apiURL             = URL(string: "https://api.github.com/repos/kanzie/meorthem/releases/latest")!
    private let requestTimeout: TimeInterval = 15
    private let checkInterval:  TimeInterval = 24 * 3600
    private let maxStartupRetries = 5
    private let startupRetryDelay: UInt64 = 60 * 1_000_000_000  // 60 s in nanoseconds

    private var timer: Timer?
    /// Guards against concurrent checks (manual + timer + retry overlapping).
    private var isChecking = false

    private enum UDKey {
        static let lastCheck    = "updateChecker.lastCheckDate"
        static let lastStatus   = "updateChecker.lastCheckStatus"   // "ok" | "failed"
        static let skippedTag   = "updateChecker.skippedTag"
    }

    @Published private(set) var lastCheckDescription: String

    private init() {
        lastCheckDescription = Self.buildDescription()
    }

    // MARK: - Public API

    /// Call once on startup. Checks immediately with retry; schedules 24 h periodic rechecks.
    func startPeriodicChecks() {
        schedulePeriodicTimer()
        Task { await startupCheckWithRetry() }
    }

    /// Manual trigger from Settings. Always surfaces a result to the user.
    func checkManually() {
        Task { await fetchAndEvaluate(manual: true) }
    }

    // MARK: - Startup retry

    private func startupCheckWithRetry() async {
        for attempt in 1...maxStartupRetries {
            let reachable = await fetchAndEvaluate(manual: false)
            if reachable { return }
            guard attempt < maxStartupRetries else { return }
            try? await Task.sleep(nanoseconds: startupRetryDelay)
        }
    }

    // MARK: - Periodic timer

    private func schedulePeriodicTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchAndEvaluate(manual: false)
            }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Core fetch

    /// Fetches the latest GitHub release and evaluates whether to prompt the user.
    /// Returns `true` if GitHub was reachable (regardless of whether an update was found).
    @discardableResult
    private func fetchAndEvaluate(manual: Bool) async -> Bool {
        // Singleton guard: only one check at a time
        guard !isChecking else { return true }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: apiURL,
                                 cachePolicy: .useProtocolCachePolicy,
                                 timeoutInterval: requestTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28",                  forHTTPHeaderField: "X-GitHub-Api-Version")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: data)
        else {
            // Network / parse failure
            recordCheck(status: "failed")
            if manual { showConnectionError() }
            return false
        }

        // Successful contact — record timestamp
        recordCheck(status: "ok")

        let current = currentVersion()
        let latest  = release.version
        let skipped = UserDefaults.standard.string(forKey: UDKey.skippedTag)

        guard isNewer(latest, than: current) else {
            if manual { showAlreadyUpToDate(current: current) }
            return true
        }

        if !manual && skipped == release.tagName { return true }

        guard release.dmgURL != nil else {
            if manual { showAlreadyUpToDate(current: current) }
            return true
        }

        UpdateWindowController.shared.show(release: release, currentVersion: current)
        return true
    }

    // MARK: - Helpers

    private func recordCheck(status: String) {
        UserDefaults.standard.set(Date(),  forKey: UDKey.lastCheck)
        UserDefaults.standard.set(status,  forKey: UDKey.lastStatus)
        lastCheckDescription = Self.buildDescription()
    }

    private static func buildDescription() -> String {
        let ud = UserDefaults.standard
        guard let date = ud.object(forKey: UDKey.lastCheck) as? Date else { return "Never" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        let ds = f.string(from: date)
        let status = ud.string(forKey: UDKey.lastStatus) ?? "ok"
        return status == "failed" ? "Failed to connect to github.com (\(ds))" : ds
    }

    private func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private func isNewer(_ candidate: String, than base: String) -> Bool {
        let lhs = components(candidate); let rhs = components(base)
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
        alert.messageText    = "You're up to date!"
        alert.informativeText = "Me Or Them \(current) is the latest version."
        alert.alertStyle     = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showConnectionError() {
        let alert = NSAlert()
        alert.messageText     = "Could not check for updates"
        alert.informativeText = "Me Or Them couldn't reach github.com. Please check your internet connection and try again."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Skip

    static func skipVersion(_ tagName: String) {
        UserDefaults.standard.set(tagName, forKey: UDKey.skippedTag)
    }
}
