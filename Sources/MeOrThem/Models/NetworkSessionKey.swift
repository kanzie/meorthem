import Foundation

/// A stable fingerprint for a network environment derived from data already
/// available in WiFiSnapshot — no additional permissions required.
///
/// The fingerprint combines:
///   • Gateway IP   — identifies the router / LAN
///   • WiFi channel — distinguishes band switches on the same router
///   • Band (GHz)   — belt-and-suspenders with channel
///   • Subnet /24   — catches multi-router environments with the same channel
///
/// When any component changes, a new session should be opened.
struct NetworkSessionKey: Equatable {

    /// Opaque string key used for SQLite lookups.
    let fingerprint: String

    /// Short human-readable label shown in the Network Analysis UI,
    /// e.g. "5 GHz • 192.168.1.x" or "Ethernet • 10.0.0.x"
    let displayName: String

    // MARK: - Factory

    /// Creates a key from a WiFi snapshot. Returns nil when the snapshot lacks
    /// the minimum required fields (routerIP + channelNumber).
    static func from(wifi: WiFiSnapshot) -> NetworkSessionKey? {
        guard let gw = wifi.routerIP, !gw.isEmpty else { return nil }
        let subnet  = subnetPrefix(ip: wifi.ipAddress)
        let ghzStr  = bandLabel(wifi.channelBandGHz)
        let fp      = "\(gw)|\(wifi.channelNumber)|\(ghzStr)|\(subnet)"
        let name    = "\(ghzStr) • \(subnet).x"
        return NetworkSessionKey(fingerprint: fp, displayName: name)
    }

    /// Creates a key for an Ethernet / non-WiFi session.
    static func fromEthernet(gatewayIP: String, localIP: String?) -> NetworkSessionKey {
        let subnet = subnetPrefix(ip: localIP)
        let fp     = "eth|\(gatewayIP)|\(subnet)"
        let name   = "Ethernet • \(subnet).x"
        return NetworkSessionKey(fingerprint: fp, displayName: name)
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
