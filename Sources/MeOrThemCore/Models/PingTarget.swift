import Foundation

struct PingTarget: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var label: String
    var host: String
    /// System targets (e.g., Gateway) are not editable or removable by the user.
    var isSystem: Bool

    init(id: UUID = UUID(), label: String, host: String, isSystem: Bool = false) {
        self.id = id
        self.label = label
        self.host = host
        self.isSystem = isSystem
    }

    // Custom Codable: isSystem is never persisted — user targets are always non-system.
    enum CodingKeys: String, CodingKey { case id, label, host }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self,   forKey: .id)
        label    = try c.decode(String.self, forKey: .label)
        host     = try c.decode(String.self, forKey: .host)
        isSystem = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,    forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(host,  forKey: .host)
    }

    /// Fixed ID used for the gateway system target (consistent across sessions).
    static let gatewayID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static let defaults: [PingTarget] = [
        PingTarget(label: "Cloudflare",    host: "1.1.1.1"),
        PingTarget(label: "Google",        host: "8.8.8.8"),
        PingTarget(label: "Quad9",         host: "9.9.9.9"),
        PingTarget(label: "OpenDNS",       host: "208.67.222.222"),
        PingTarget(label: "CleanBrowsing", host: "185.228.168.9"),
    ]
}
