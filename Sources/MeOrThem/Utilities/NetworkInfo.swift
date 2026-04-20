import Foundation
import Darwin

/// Low-level helpers for IP address and default gateway lookup.
/// Uses POSIX getifaddrs and a subprocess — no shell expansion, no injection surface.
enum NetworkInfo {

    // MARK: - Cache (results rarely change; refresh at most every 30s)

    private static let kCacheTTL: TimeInterval = 30
    private static let cacheLock = NSLock()

    nonisolated(unsafe) private static var _cachedGateway: String?          = nil
    nonisolated(unsafe) private static var _cachedGatewayInterface: String? = nil
    nonisolated(unsafe) private static var _gatewayFetchedAt: Date          = .distantPast

    nonisolated(unsafe) private static var _lastIPQuery: (interface: String, ip: String?, fetchedAt: Date)?

    // MAC cache — keyed on the queried IP to invalidate when the gateway IP changes.
    nonisolated(unsafe) private static var _cachedMAC: String?  = nil
    nonisolated(unsafe) private static var _macCacheKey: String = ""
    nonisolated(unsafe) private static var _macFetchedAt: Date  = .distantPast

    // MARK: - Public API

    /// Returns the IPv4 address of the named interface (e.g. "en0"), or nil.
    static func ipAddress(for interfaceName: String) -> String? {
        cacheLock.lock()
        let now = Date()
        if let cached = _lastIPQuery,
           cached.interface == interfaceName,
           now.timeIntervalSince(cached.fetchedAt) < kCacheTTL {
            let ip = cached.ip
            cacheLock.unlock()
            return ip
        }
        cacheLock.unlock()
        let result = fetchIPAddress(for: interfaceName)
        cacheLock.lock()
        _lastIPQuery = (interfaceName, result, now)
        cacheLock.unlock()
        return result
    }

    /// Returns the IPv4 default gateway address, or nil.
    static func defaultGateway() -> String? {
        cacheLock.lock()
        let now = Date()
        if now.timeIntervalSince(_gatewayFetchedAt) < kCacheTTL {
            let gw = _cachedGateway
            cacheLock.unlock()
            return gw
        }
        cacheLock.unlock()
        let (gw, iface) = fetchDefaultRouteInfo()
        cacheLock.lock()
        _gatewayFetchedAt       = now
        _cachedGateway          = gw
        _cachedGatewayInterface = iface
        cacheLock.unlock()
        return gw
    }

    /// Returns the network interface name used for the default route, or nil.
    /// Examples: "en0" (WiFi), "en1" (Ethernet), "utun3" (VPN), "ppp0" (PPP/VPN).
    /// Shares the gateway cache — calling both defaultGateway() and defaultGatewayInterface()
    /// within the same 30-second window spawns only one subprocess.
    static func defaultGatewayInterface() -> String? {
        cacheLock.lock()
        let now = Date()
        if now.timeIntervalSince(_gatewayFetchedAt) < kCacheTTL {
            let iface = _cachedGatewayInterface
            cacheLock.unlock()
            return iface
        }
        cacheLock.unlock()
        let (gw, iface) = fetchDefaultRouteInfo()
        cacheLock.lock()
        _gatewayFetchedAt       = now
        _cachedGateway          = gw
        _cachedGatewayInterface = iface
        cacheLock.unlock()
        return iface
    }

    /// Returns the MAC address of the specified IPv4 gateway from the ARP cache.
    /// Runs `arp -n <ip>` — the IP is validated via inet_pton before use to prevent injection.
    /// Returns nil on ARP miss, incomplete entry, invalid input, or subprocess failure.
    /// Results are cached for 30 seconds; the cache is invalidated when the queried IP changes.
    static func gatewayMACAddress(for ip: String) -> String? {
        // Validate: must be a well-formed IPv4 address.
        var dummy = in_addr()
        guard inet_pton(AF_INET, ip, &dummy) == 1 else { return nil }

        cacheLock.lock()
        let now = Date()
        if _macCacheKey == ip, now.timeIntervalSince(_macFetchedAt) < kCacheTTL {
            let mac = _cachedMAC
            cacheLock.unlock()
            return mac
        }
        cacheLock.unlock()

        let result = fetchGatewayMAC(ip: ip)
        cacheLock.lock()
        _macCacheKey  = ip
        _macFetchedAt = now
        _cachedMAC    = result
        cacheLock.unlock()
        return result
    }

    /// Returns info for the primary active ethernet interface, if any.
    /// Excludes the named WiFi interface so WiFi adapters are not misidentified as Ethernet.
    /// Single getifaddrs pass — collects both IP (AF_INET) and MAC (AF_LINK).
    static func ethernetInfo(excluding wifiInterface: String? = nil) -> (interface: String, ip: String, mac: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidate: (name: String, ip: String)?
        var macMap: [String: String] = [:]

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            let name   = String(cString: iface.pointee.ifa_name)
            guard let ifaAddr = iface.pointee.ifa_addr else { ptr = iface.pointee.ifa_next; continue }
            let family = ifaAddr.pointee.sa_family

            if name.hasPrefix("en") {
                if name == wifiInterface { ptr = iface.pointee.ifa_next; continue }
                if family == UInt8(AF_INET), candidate == nil {
                    var addr = ifaAddr.withMemoryRebound(
                        to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: buf)
                    if !ip.hasPrefix("127.") { candidate = (name, ip) }

                } else if family == UInt8(AF_LINK) {
                    let sdl  = ifaAddr.withMemoryRebound(
                        to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                    let len  = Int(sdl.sdl_alen)
                    let nlen = Int(sdl.sdl_nlen)
                    if len == 6 {
                        var mac = [UInt8](repeating: 0, count: 6)
                        withUnsafeBytes(of: sdl.sdl_data) { raw in
                            for i in 0..<6 { mac[i] = raw[nlen + i] }
                        }
                        macMap[name] = mac.map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                }
            }
            ptr = iface.pointee.ifa_next
        }

        guard let found = candidate else { return nil }
        return (found.name, found.ip, macMap[found.name] ?? "—")
    }

    // MARK: - Private subprocess helpers

    /// Runs `/sbin/route -n get default` and returns both the gateway IP and interface name.
    private static func fetchDefaultRouteInfo() -> (gateway: String?, interface: String?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/route")
        task.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return (nil, nil)
        }
        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return NetworkInfo.parseRouteInfo(from: output)
    }

    /// Runs `/usr/sbin/arp -n <ip>` and returns the gateway's MAC address, or nil.
    private static func fetchGatewayMAC(ip: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-n", ip]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return NetworkInfo.parseMACFromARPOutput(output)
    }

    private static func fetchIPAddress(for interfaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            let name = String(cString: iface.pointee.ifa_name)
            guard let ifaAddr = iface.pointee.ifa_addr else { ptr = iface.pointee.ifa_next; continue }
            if name == interfaceName,
               ifaAddr.pointee.sa_family == UInt8(AF_INET) {
                var addr = ifaAddr.withMemoryRebound(
                    to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buf)
            }
            ptr = iface.pointee.ifa_next
        }
        return nil
    }
}

// MARK: - Internal parsing helpers (mirrored from Core; exposed for call sites in app target)

extension NetworkInfo {
    /// Parses `gateway:` and `interface:` values from `/sbin/route -n get default` output.
    static func parseRouteInfo(from output: String) -> (gateway: String?, interface: String?) {
        var gateway:   String?
        var interface: String?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = String(trimmed.dropFirst("gateway:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                interface = String(trimmed.dropFirst("interface:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            if gateway != nil, interface != nil { break }
        }
        return (gateway, interface)
    }

    /// Parses a MAC address from `/usr/sbin/arp -n <ip>` output.
    /// Returns nil for ARP misses or unparseable output.
    static func parseMACFromARPOutput(_ output: String) -> String? {
        for line in output.components(separatedBy: "\n") {
            guard line.contains(" at ") else { continue }
            let parts = line.components(separatedBy: " at ")
            guard parts.count >= 2 else { continue }
            let candidate = parts[1].components(separatedBy: " on ")[0]
                .trimmingCharacters(in: .whitespaces)
            if candidate.isEmpty || candidate.hasPrefix("(") { return nil }
            return candidate
        }
        return nil
    }
}
