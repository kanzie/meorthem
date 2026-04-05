import Foundation
import Darwin

/// Low-level helpers for IP address and default gateway lookup.
/// Uses POSIX getifaddrs and a subprocess — no shell expansion, no injection surface.
public enum NetworkInfo {

    // MARK: - Cache (results rarely change; refresh at most every 30s)

    private static let kCacheTTL: TimeInterval = 30

    nonisolated(unsafe) private static var _cachedGateway: String?  = nil
    nonisolated(unsafe) private static var _gatewayFetchedAt: Date  = .distantPast

    nonisolated(unsafe) private static var _lastIPQuery: (interface: String, ip: String?, fetchedAt: Date)?

    // MARK: - Public API

    /// Returns the IPv4 address of the named interface (e.g. "en0"), or nil.
    public static func ipAddress(for interfaceName: String) -> String? {
        let now = Date()
        if let cached = _lastIPQuery,
           cached.interface == interfaceName,
           now.timeIntervalSince(cached.fetchedAt) < kCacheTTL {
            return cached.ip
        }
        let result = fetchIPAddress(for: interfaceName)
        _lastIPQuery = (interfaceName, result, now)
        return result
    }

    /// Returns the IPv4 default gateway address, or nil.
    public static func defaultGateway() -> String? {
        let now = Date()
        if now.timeIntervalSince(_gatewayFetchedAt) < kCacheTTL {
            return _cachedGateway
        }
        _gatewayFetchedAt = now
        _cachedGateway = fetchDefaultGateway()
        return _cachedGateway
    }

    /// Returns info for the primary active ethernet interface, if any.
    /// Single getifaddrs pass — collects both IP (AF_INET) and MAC (AF_LINK).
    public static func ethernetInfo() -> (interface: String, ip: String, mac: String)? {
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

    // MARK: - Private

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

    private static func fetchDefaultGateway() -> String? {
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
            return nil
        }
        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                return trimmed
                    .dropFirst("gateway:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
