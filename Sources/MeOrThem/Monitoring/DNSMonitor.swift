import Foundation
import Darwin

/// Measures DNS resolution time using the system resolver.
/// Blocking — always call from a background thread or detached Task.
enum DNSMonitor {

    /// Fixed hostname used for all DNS sampling. Resolving dns.google tests the full
    /// system resolver stack (local cache, router DNS relay, ISP resolver, root servers)
    /// and is reliably available worldwide.
    static let testHostname = "dns.google"

    /// Resolves `hostname` via the system resolver and returns elapsed wall-clock
    /// time in milliseconds. Returns `nil` when resolution fails (NXDOMAIN, timeout, etc.).
    static func measure(hostname: String = testHostname) -> Double? {
        var hints     = addrinfo()
        hints.ai_family   = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>? = nil

        let start = Date()
        let ret   = getaddrinfo(hostname, nil, &hints, &result)
        let elapsed = -start.timeIntervalSinceNow * 1_000.0   // convert s → ms

        if result != nil { freeaddrinfo(result) }
        return ret == 0 ? elapsed : nil
    }
}
