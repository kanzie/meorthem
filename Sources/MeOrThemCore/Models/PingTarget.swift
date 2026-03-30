import Foundation

struct PingTarget: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var label: String
    var host: String

    init(id: UUID = UUID(), label: String, host: String) {
        self.id = id
        self.label = label
        self.host = host
    }

    static let defaults: [PingTarget] = [
        PingTarget(label: "Cloudflare", host: "1.1.1.1"),
        PingTarget(label: "Google",     host: "8.8.8.8"),
        PingTarget(label: "Quad9",      host: "9.9.9.9"),
        PingTarget(label: "OpenDNS",    host: "208.67.222.222"),
        PingTarget(label: "CleanBrowsing", host: "185.228.168.9"),
    ]
}
