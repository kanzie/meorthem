import Foundation
import MeOrThemCore

/// A stable fingerprint for a network environment, independent of connection type.
///
/// ## WiFi
/// Combines gateway IP + channel + band + subnet /24. Channel and band disambiguate
/// routers that share the same IP, and distinguish band switches on the same router.
///
/// ## Ethernet
/// Combines gateway IP + subnet /24 + gateway MAC address (from ARP cache).
/// The router hardware address is the primary discriminator — two routers sharing the
/// same IP will have different MACs. When the MAC is unavailable (ARP miss at session
/// open time), `hasWeakFingerprint` is set to true and a UI advisory is shown.
///
/// ## VPN
/// Combines interface name + gateway IP + subnet /24. The interface name (e.g. "utun3")
/// is included because VPN tunnel numbers are assigned per-connection instance.
///
/// When any component changes, a new session should be opened.
struct NetworkSessionKey: Equatable {

    // MARK: - Connection type

    enum ConnectionType: String {
        case wifi     = "wifi"
        case ethernet = "ethernet"
        case vpn      = "vpn"
        case unknown  = "unknown"
    }

    // MARK: - Properties

    /// Opaque string key used for SQLite lookups and session-change detection.
    let fingerprint: String

    /// Short human-readable label shown in the Network Analysis UI,
    /// e.g. "5 GHz • 192.168.1.x", "Ethernet • 10.0.0.x", "VPN • 10.8.0.x"
    let displayName: String

    /// The type of network connection this fingerprint was derived from.
    let connectionType: ConnectionType

    /// True when the Ethernet fingerprint lacks a gateway MAC address.
    /// In this case the session may silently merge two different Ethernet
    /// networks that share the same gateway IP and /24 subnet.
    let hasWeakFingerprint: Bool

    // MARK: - Factory (WiFi)

    /// Creates a key from a WiFi snapshot. Returns nil when the snapshot lacks
    /// the minimum required fields (routerIP + channelNumber).
    static func from(wifi: WiFiSnapshot) -> NetworkSessionKey? {
        guard let gw = wifi.routerIP, !gw.isEmpty else { return nil }
        let subnet = subnetPrefix(ip: wifi.ipAddress)
        let ghzStr = bandLabel(wifi.channelBandGHz)
        let fp     = "\(gw)|\(wifi.channelNumber)|\(ghzStr)|\(subnet)"
        let name   = "\(ghzStr) • \(subnet).x"
        return NetworkSessionKey(fingerprint: fp, displayName: name,
                                 connectionType: .wifi, hasWeakFingerprint: false)
    }

    // MARK: - Factory (Ethernet)

    /// Creates a key for an Ethernet session.
    ///
    /// - Parameters:
    ///   - gatewayIP: The default gateway IP address.
    ///   - localIP: The local IP on the active Ethernet interface (used for subnet prefix).
    ///   - gatewayMAC: The ARP-cache MAC address of the gateway router. When nil or
    ///     unresolvable the fingerprint is weaker; `hasWeakFingerprint` is set to true.
    static func fromEthernet(gatewayIP: String,
                              localIP: String?,
                              gatewayMAC: String?) -> NetworkSessionKey {
        let subnet = subnetPrefix(ip: localIP)
        let mac    = gatewayMAC?.lowercased() ?? ""
        let hasMAC = !mac.isEmpty && !mac.hasPrefix("(")
        let fp     = hasMAC
            ? "eth|\(gatewayIP)|\(subnet)|\(mac)"
            : "eth|\(gatewayIP)|\(subnet)"
        let name   = "Ethernet • \(subnet).x"
        return NetworkSessionKey(fingerprint: fp, displayName: name,
                                 connectionType: .ethernet, hasWeakFingerprint: !hasMAC)
    }

    // MARK: - Factory (VPN)

    /// Creates a key for a VPN session.
    ///
    /// - Parameters:
    ///   - gatewayIP: The VPN gateway IP (from the routing table).
    ///   - localIP: The VPN-assigned local IP (used for subnet prefix).
    ///   - interfaceName: The tunnel interface name, e.g. "utun3" or "ppp0".
    static func fromVPN(gatewayIP: String,
                        localIP: String?,
                        interfaceName: String) -> NetworkSessionKey {
        let subnet = subnetPrefix(ip: localIP)
        let fp     = "vpn|\(interfaceName)|\(gatewayIP)|\(subnet)"
        let name   = "VPN • \(subnet).x"
        return NetworkSessionKey(fingerprint: fp, displayName: name,
                                 connectionType: .vpn, hasWeakFingerprint: false)
    }

    // MARK: - Helpers

    /// Returns the first three octets of an IPv4 address, or "?.?.?" if unresolvable.
    private static func subnetPrefix(ip: String?) -> String {
        guard let ip else { return "?.?.?" }
        let parts = ip.split(separator: ".", maxSplits: 3)
        guard parts.count >= 3 else { return "?.?.?" }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    private static func bandLabel(_ ghz: Double) -> String {
        // Use tolerance comparison rather than exact Double equality.
        // CWChannel.channelBand is an enum mapped to a Double constant, but
        // floating-point representation of 2.4 is not exact; a mismatch would
        // fall through to the default branch, producing a different fingerprint
        // string and silently opening a spurious new network_sessions row.
        if abs(ghz - 2.4) < 0.05 { return "2.4 GHz" }
        if abs(ghz - 5.0) < 0.05 { return "5 GHz" }
        if abs(ghz - 6.0) < 0.05 { return "6 GHz" }
        return String(format: "%.1f GHz", ghz)
    }
}
