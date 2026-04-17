import Foundation

/// A configurable DNS resolver entry used for multi-resolver latency monitoring.
/// Codable for UserDefaults persistence. Identifiable for SwiftUI list binding.
public struct DNSResolver: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID

    /// Human-readable label shown in settings and the menu.
    public var name: String

    /// Static resolver IP (e.g. "8.8.8.8"). Ignored when `isSystem` or `isGateway` is true.
    public var ip: String

    /// Whether this resolver is included in sampling runs.
    public var isEnabled: Bool

    /// If true, the IP is resolved at probe time by reading /etc/resolv.conf.
    public var isSystem: Bool

    /// If true, the IP is taken from MonitoringEngine's last-known gateway address.
    public var isGateway: Bool

    /// Incremented each time a probe fails while ≥1 other resolver succeeds.
    /// Persisted so a resolver auto-disabled before restart stays disabled.
    public var consecutiveFailures: Int

    /// Set when `consecutiveFailures` reaches the auto-disable threshold.
    /// Cleared on first successful re-probe.
    public var autoDisabledAt: Date?

    public init(id: UUID = UUID(),
                name: String,
                ip: String,
                isEnabled: Bool = true,
                isSystem: Bool = false,
                isGateway: Bool = false,
                consecutiveFailures: Int = 0,
                autoDisabledAt: Date? = nil) {
        self.id = id
        self.name = name
        self.ip = ip
        self.isEnabled = isEnabled
        self.isSystem = isSystem
        self.isGateway = isGateway
        self.consecutiveFailures = consecutiveFailures
        self.autoDisabledAt = autoDisabledAt
    }
}

// MARK: - Pre-populated resolver list

public extension DNSResolver {

    /// Number of consecutive per-resolver failures (while ≥1 other succeeds)
    /// before the resolver is auto-disabled. At the default 5s poll interval
    /// and every-6th-tick DNS sampling (~30s cadence), 10 failures ≈ 5 minutes.
    static let autoDisableThreshold = 10

    /// The canonical pre-populated resolver list. Five are enabled by default
    /// (Cloudflare, Google, Quad9, System, Gateway); the rest are off.
    static let defaults: [DNSResolver] = [
        DNSResolver(name: "Cloudflare",           ip: "1.1.1.1",           isEnabled: true),
        DNSResolver(name: "Cloudflare (alt)",     ip: "1.0.0.1",           isEnabled: false),
        DNSResolver(name: "Google",               ip: "8.8.8.8",           isEnabled: true),
        DNSResolver(name: "Google (alt)",         ip: "8.8.4.4",           isEnabled: false),
        DNSResolver(name: "Quad9",                ip: "9.9.9.9",           isEnabled: true),
        DNSResolver(name: "Quad9 (alt)",          ip: "149.112.112.112",   isEnabled: false),
        DNSResolver(name: "OpenDNS",              ip: "208.67.222.222",    isEnabled: false),
        DNSResolver(name: "OpenDNS (alt)",        ip: "208.67.220.220",    isEnabled: false),
        DNSResolver(name: "AdGuard DNS",          ip: "94.140.14.14",      isEnabled: false),
        DNSResolver(name: "AdGuard DNS (alt)",    ip: "94.140.15.15",      isEnabled: false),
        // IPv6 variants — disabled by default; only meaningful with IPv6 connectivity
        DNSResolver(name: "Cloudflare (IPv6)",    ip: "2606:4700:4700::1111", isEnabled: false),
        DNSResolver(name: "Google (IPv6)",        ip: "2001:4860:4860::8888", isEnabled: false),
        // Dynamic entries — IP resolved at probe time
        DNSResolver(name: "System Resolver",      ip: "",  isEnabled: true,  isSystem: true),
        DNSResolver(name: "Gateway / Router",     ip: "",  isEnabled: true,  isGateway: true),
    ]
}
