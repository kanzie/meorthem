import Foundation
import Combine
import MeOrThemCore

enum ColorTheme: String, Codable, CaseIterable {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Ping targets
    @Published var pingTargets: [PingTarget] {
        didSet { encode(pingTargets, forKey: "pingTargets") }
    }

    // MARK: - Thresholds
    @Published var thresholds: Thresholds {
        didSet { encode(thresholds, forKey: "thresholds") }
    }

    // MARK: - General
    @Published var alwaysShowBarChart: Bool {
        didSet { UserDefaults.standard.set(alwaysShowBarChart, forKey: "alwaysShowBarChart") }
    }

    @Published var colorTheme: ColorTheme {
        didSet { UserDefaults.standard.set(colorTheme.rawValue, forKey: "colorTheme") }
    }

    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }

    @Published var pollIntervalSecs: Double {
        didSet {
            UserDefaults.standard.set(pollIntervalSecs, forKey: "pollIntervalSecs")
            // Evaluation windows must always be at least one poll interval long.
            if latencyWindowSecs < pollIntervalSecs { latencyWindowSecs = pollIntervalSecs }
            if lossWindowSecs    < pollIntervalSecs { lossWindowSecs    = pollIntervalSecs }
            if jitterWindowSecs  < pollIntervalSecs { jitterWindowSecs  = pollIntervalSecs }
        }
    }

    // ── Evaluation windows (seconds) ─────────────────────────────────────────
    // Each metric is averaged over its window before being compared to thresholds.
    // Defaults: latency 15 s, loss 10 s, jitter 30 s (guards against AWDL scans).
    // All windows are clamped to ≥ pollIntervalSecs whenever that setting changes.
    @Published var latencyWindowSecs: Double {
        didSet { UserDefaults.standard.set(latencyWindowSecs, forKey: "latencyWindowSecs") }
    }
    @Published var lossWindowSecs: Double {
        didSet { UserDefaults.standard.set(lossWindowSecs, forKey: "lossWindowSecs") }
    }
    @Published var jitterWindowSecs: Double {
        didSet { UserDefaults.standard.set(jitterWindowSecs, forKey: "jitterWindowSecs") }
    }

    // MARK: - Menubar text mode
    /// When true, shows current average latency as text alongside the icon.
    @Published var showLatencyInMenubar: Bool {
        didSet { UserDefaults.standard.set(showLatencyInMenubar, forKey: "showLatencyInMenubar") }
    }

    // MARK: - Bandwidth scheduling (0 = disabled)
    /// Auto-run bandwidth test every N hours. 0 disables.
    @Published var bandwidthScheduleHours: Double {
        didSet { UserDefaults.standard.set(bandwidthScheduleHours, forKey: "bandwidthScheduleHours") }
    }

    // MARK: - Log rotation
    /// When true, daily summaries are written to ~/Library/Logs/MeOrThem/.
    @Published var enableLogRotation: Bool {
        didSet { UserDefaults.standard.set(enableLogRotation, forKey: "enableLogRotation") }
    }

    // MARK: - SQLite data retention (days)
    // Defaults: 7 days raw, 90 days per-minute aggregates, 1 year incident journal.
    @Published var rawRetentionDays: Int {
        didSet { UserDefaults.standard.set(rawRetentionDays, forKey: "rawRetentionDays") }
    }
    @Published var aggregateRetentionDays: Int {
        didSet { UserDefaults.standard.set(aggregateRetentionDays, forKey: "aggregateRetentionDays") }
    }
    @Published var incidentRetentionDays: Int {
        didSet { UserDefaults.standard.set(incidentRetentionDays, forKey: "incidentRetentionDays") }
    }

    @Published var bandwidthBarRedMbps: Double {
        didSet { UserDefaults.standard.set(bandwidthBarRedMbps, forKey: "bandwidthBarRedMbps") }
    }

    @Published var bandwidthBarYellowMbps: Double {
        didSet { UserDefaults.standard.set(bandwidthBarYellowMbps, forKey: "bandwidthBarYellowMbps") }
    }

    // MARK: - DNS Resolvers
    /// The configured multi-resolver list. On first launch after upgrade (no saved key),
    /// defaults to the pre-populated list with the default five enabled.
    @Published var dnsResolvers: [DNSResolver] {
        didSet { encode(dnsResolvers, forKey: "dnsResolvers") }
    }

    // MARK: - Notifications
    @Published var enableNotificationBanner: Bool {
        didSet { UserDefaults.standard.set(enableNotificationBanner, forKey: "enableNotificationBanner") }
    }
    @Published var enableNotificationSound: Bool {
        didSet { UserDefaults.standard.set(enableNotificationSound, forKey: "enableNotificationSound") }
    }

    private init() {
        let ud = UserDefaults.standard

        pingTargets   = (try? ud.decoded([PingTarget].self,    forKey: "pingTargets"))   ?? PingTarget.defaults
        thresholds    = (try? ud.decoded(Thresholds.self,     forKey: "thresholds"))    ?? .default
        dnsResolvers  = (try? ud.decoded([DNSResolver].self,  forKey: "dnsResolvers"))  ?? DNSResolver.defaults

        alwaysShowBarChart        = ud.bool(forKey: "alwaysShowBarChart")
        colorTheme                = ColorTheme(rawValue: ud.string(forKey: "colorTheme") ?? "") ?? .system
        launchAtLogin             = ud.object(forKey: "launchAtLogin") as? Bool ?? true
        pollIntervalSecs          = ud.double(forKey: "pollIntervalSecs").nonZero ?? 5
        showLatencyInMenubar      = ud.bool(forKey: "showLatencyInMenubar")
        bandwidthScheduleHours    = ud.double(forKey: "bandwidthScheduleHours")   // 0 = disabled
        enableLogRotation         = ud.bool(forKey: "enableLogRotation")
        bandwidthBarRedMbps       = ud.double(forKey: "bandwidthBarRedMbps").nonZero ?? 10
        bandwidthBarYellowMbps    = ud.double(forKey: "bandwidthBarYellowMbps").nonZero ?? 25
        enableNotificationBanner  = ud.object(forKey: "enableNotificationBanner") as? Bool ?? true
        enableNotificationSound   = ud.object(forKey: "enableNotificationSound")  as? Bool ?? false
        rawRetentionDays          = ud.object(forKey: "rawRetentionDays")       as? Int ?? 7
        aggregateRetentionDays    = ud.object(forKey: "aggregateRetentionDays") as? Int ?? 90
        incidentRetentionDays     = ud.object(forKey: "incidentRetentionDays")  as? Int ?? 365

        let poll = ud.double(forKey: "pollIntervalSecs").nonZero ?? 5
        latencyWindowSecs = Swift.max(ud.double(forKey: "latencyWindowSecs").nonZero ?? 15, poll)
        lossWindowSecs    = Swift.max(ud.double(forKey: "lossWindowSecs").nonZero    ?? 10, poll)
        jitterWindowSecs  = Swift.max(ud.double(forKey: "jitterWindowSecs").nonZero  ?? 30, poll)
    }

    /// Update failure tracking for one resolver after a probe round.
    /// - Parameters:
    ///   - id: The resolver's stable UUID.
    ///   - succeeded: Whether this resolver returned a valid response this tick.
    ///   - otherResolversOK: Whether ≥1 other resolver succeeded this tick.
    ///     When false (all resolvers failing), no failure count is incremented —
    ///     it's a network outage, not a resolver fault.
    func updateDNSResolverFailureCount(id: UUID, succeeded: Bool, otherResolversOK: Bool) {
        guard let idx = dnsResolvers.firstIndex(where: { $0.id == id }) else { return }
        if succeeded {
            dnsResolvers[idx].consecutiveFailures = 0
            dnsResolvers[idx].autoDisabledAt = nil
        } else if otherResolversOK {
            dnsResolvers[idx].consecutiveFailures += 1
            if dnsResolvers[idx].consecutiveFailures >= DNSResolver.autoDisableThreshold,
               dnsResolvers[idx].autoDisabledAt == nil {
                dnsResolvers[idx].autoDisabledAt = Date()
            }
        }
        // If !succeeded && !otherResolversOK: network outage — do not penalise any resolver.
    }

    /// Re-enable a resolver that was auto-disabled (called after a successful re-probe).
    func reEnableDNSResolver(id: UUID) {
        guard let idx = dnsResolvers.firstIndex(where: { $0.id == id }) else { return }
        dnsResolvers[idx].consecutiveFailures = 0
        dnsResolvers[idx].autoDisabledAt = nil
    }

    /// Reset all resolver failure counters (called on network session change).
    func resetDNSResolverFailureCounts() {
        for idx in dnsResolvers.indices {
            dnsResolvers[idx].consecutiveFailures = 0
            dnsResolvers[idx].autoDisabledAt = nil
        }
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? _sharedEncoder.encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// Shared codec instances — JSONEncoder/Decoder are expensive to allocate (~0.1ms each).
// Settings are @MainActor so no concurrent access is possible.
private let _sharedEncoder = JSONEncoder()
private let _sharedDecoder = JSONDecoder()

// MARK: - UserDefaults helpers
private extension UserDefaults {
    func decoded<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T {
        guard let data = data(forKey: key) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No data for key \(key)"))
        }
        return try _sharedDecoder.decode(type, from: data)
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
