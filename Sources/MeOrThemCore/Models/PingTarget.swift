import Foundation

/// How a ping target's reachability is measured each poll tick.
public enum ProbeMode: String, Codable, CaseIterable, Sendable {
    case icmp  = "ICMP"
    case tcp   = "TCP"
    case http  = "HTTP"
    case https = "HTTPS"
}

public struct PingTarget: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var host: String
    /// How to probe this target. Defaults to `.icmp`.
    public var probeMode: ProbeMode
    /// System targets (e.g., Gateway) are not editable or removable by the user.
    public var isSystem: Bool
    /// Optional per-target threshold overrides. When non-nil, used instead of global thresholds.
    public var thresholdOverride: Thresholds?

    public init(id: UUID = UUID(), label: String, host: String, probeMode: ProbeMode = .icmp,
                isSystem: Bool = false, thresholdOverride: Thresholds? = nil) {
        self.id                = id
        self.label             = label
        self.host              = host
        self.probeMode         = probeMode
        self.isSystem          = isSystem
        self.thresholdOverride = thresholdOverride
    }

    // Custom Codable: isSystem is never persisted — user targets are always non-system.
    // probeMode defaults to .icmp when absent for backward compatibility with saved data.
    enum CodingKeys: String, CodingKey { case id, label, host, probeMode, thresholdOverride }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = try c.decode(UUID.self,   forKey: .id)
        label             = try c.decode(String.self, forKey: .label)
        host              = try c.decode(String.self, forKey: .host)
        probeMode         = (try? c.decodeIfPresent(ProbeMode.self, forKey: .probeMode) ?? nil) ?? .icmp
        isSystem          = false
        thresholdOverride = try? c.decodeIfPresent(Thresholds.self, forKey: .thresholdOverride) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,        forKey: .id)
        try c.encode(label,     forKey: .label)
        try c.encode(host,      forKey: .host)
        try c.encode(probeMode, forKey: .probeMode)
        try c.encodeIfPresent(thresholdOverride, forKey: .thresholdOverride)
    }

    /// Fixed ID used for the gateway system target (consistent across sessions).
    public static let gatewayID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public static let defaults: [PingTarget] = [
        PingTarget(label: "Cloudflare",    host: "1.1.1.1"),
        PingTarget(label: "Google",        host: "8.8.8.8"),
        PingTarget(label: "Quad9",         host: "9.9.9.9"),
        PingTarget(label: "OpenDNS",       host: "208.67.222.222"),
        PingTarget(label: "CleanBrowsing", host: "185.228.168.9"),
    ]
}
