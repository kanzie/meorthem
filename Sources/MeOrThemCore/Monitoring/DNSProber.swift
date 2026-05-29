import Foundation
import Darwin

/// Raw UDP DNS query engine.
///
/// All methods are blocking and must be called from a background thread
/// or a detached Task. They never touch any @Published state.
///
/// Design: bypass mDNSResponder (OS cache) by building a minimal DNS A-record
/// query in wire format, sending it over a UDP socket directly to the target
/// resolver IP, and measuring round-trip time. The OS cache is irrelevant here —
/// we are measuring the resolver's own response time, which correctly includes
/// its internal cache.
public enum DNSProber {

    // MARK: - Public API

    /// Send a DNS A-record query for `queryHost` to `resolverIP` and return
    /// `(resolveMs, rcode)`. Both values are nil on timeout or socket error.
    /// `rcode` is non-nil whenever the resolver sends any response.
    ///
    /// - Parameters:
    ///   - resolverIP: IPv4 or IPv6 address string (e.g. "1.1.1.1").
    ///   - queryHost:  Hostname to query. Default: "example.com" (IANA-maintained,
    ///                 never NXDOMAIN in legitimate resolvers).
    ///   - timeoutSecs: Socket receive timeout. Default 3 s.
    /// - Returns: `(resolveMs: Double?, rcode: Int?)` — both nil on hard failure.
    public static func probe(resolverIP: String,
                      queryHost: String = "example.com",
                      timeoutSecs: Int = 3) -> (resolveMs: Double?, rcode: Int?) {

        let isIPv6 = resolverIP.contains(":")
        let family: Int32 = isIPv6 ? AF_INET6 : AF_INET
        let sockFd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard sockFd >= 0 else { return (nil, nil) }
        defer { Darwin.close(sockFd) }

        // Set receive timeout so a non-responding resolver doesn't block the thread.
        var tv = timeval(tv_sec: timeoutSecs, tv_usec: 0)
        guard setsockopt(sockFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            return (nil, nil)
        }

        // Build the DNS query with a random transaction ID.
        let txID = UInt16.random(in: 1...UInt16.max)
        let query = buildQuery(id: txID, hostname: queryHost)

        // Connect to resolver (sets the default destination for send()).
        // Use withUnsafeMutableBytes on a local var to avoid nested-closure type inference issues.
        let connectResult: Int32
        if isIPv6 {
            guard var addr6 = sockaddr_in6(ip: resolverIP, port: 53) else { return (nil, nil) }
            connectResult = withUnsafeMutableBytes(of: &addr6) { rawBuf in
                rawBuf.withMemoryRebound(to: sockaddr.self) { saBuf in
                    Darwin.connect(sockFd, saBuf.baseAddress!, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            guard var addr4 = sockaddr_in(ip: resolverIP, port: 53) else { return (nil, nil) }
            connectResult = withUnsafeMutableBytes(of: &addr4) { rawBuf in
                rawBuf.withMemoryRebound(to: sockaddr.self) { saBuf in
                    Darwin.connect(sockFd, saBuf.baseAddress!, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard connectResult == 0 else { return (nil, nil) }

        // Send the query and measure elapsed time.
        let start = Date()
        let sent: Int = query.withUnsafeBytes { buf in
            Darwin.send(sockFd, buf.baseAddress!, buf.count, 0)
        }
        guard sent == query.count else { return (nil, nil) }

        // Receive response (blocking up to timeoutSecs).
        var response = [UInt8](repeating: 0, count: 512)
        let received = Darwin.recv(sockFd, &response, response.count, 0)
        let elapsedMs = -start.timeIntervalSinceNow * 1_000.0

        guard received >= 12 else { return (nil, nil) }  // minimum DNS header size

        let data = Data(response.prefix(received))
        if let rcode = validateResponse(data, expectedID: txID) {
            return (elapsedMs, rcode)
        }
        // Response received but transaction ID mismatch — treat as no response.
        return (nil, nil)
    }

    /// Probe and return both RTT/RCODE and the first resolved IPv4 address from the answer section.
    /// The `resolvedIP` is the first A-record answer if any, nil otherwise.
    /// All other parameters and semantics match `probe(resolverIP:queryHost:timeoutSecs:)`.
    public static func probeWithAnswer(resolverIP: String,
                                       queryHost: String = "example.com",
                                       timeoutSecs: Int = 3) -> (resolveMs: Double?, rcode: Int?, resolvedIP: String?) {

        let isIPv6 = resolverIP.contains(":")
        let family: Int32 = isIPv6 ? AF_INET6 : AF_INET
        let sockFd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard sockFd >= 0 else { return (nil, nil, nil) }
        defer { Darwin.close(sockFd) }

        var tv = timeval(tv_sec: timeoutSecs, tv_usec: 0)
        guard setsockopt(sockFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            return (nil, nil, nil)
        }

        let txID = UInt16.random(in: 1...UInt16.max)
        let query = buildQuery(id: txID, hostname: queryHost)

        let connectResult: Int32
        if isIPv6 {
            guard var addr6 = sockaddr_in6(ip: resolverIP, port: 53) else { return (nil, nil, nil) }
            connectResult = withUnsafeMutableBytes(of: &addr6) { rawBuf in
                rawBuf.withMemoryRebound(to: sockaddr.self) { saBuf in
                    Darwin.connect(sockFd, saBuf.baseAddress!, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            guard var addr4 = sockaddr_in(ip: resolverIP, port: 53) else { return (nil, nil, nil) }
            connectResult = withUnsafeMutableBytes(of: &addr4) { rawBuf in
                rawBuf.withMemoryRebound(to: sockaddr.self) { saBuf in
                    Darwin.connect(sockFd, saBuf.baseAddress!, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard connectResult == 0 else { return (nil, nil, nil) }

        let start = Date()
        let sent: Int = query.withUnsafeBytes { buf in
            Darwin.send(sockFd, buf.baseAddress!, buf.count, 0)
        }
        guard sent == query.count else { return (nil, nil, nil) }

        var response = [UInt8](repeating: 0, count: 512)
        let received = Darwin.recv(sockFd, &response, response.count, 0)
        let elapsedMs = -start.timeIntervalSinceNow * 1_000.0

        guard received >= 12 else { return (nil, nil, nil) }

        let data = Data(response.prefix(received))
        guard let rcode = validateResponse(data, expectedID: txID) else { return (nil, nil, nil) }

        // Parse the first A-record answer from the response.
        let resolvedIP = parseFirstARecord(from: data, queryName: queryHost)
        return (elapsedMs, rcode, resolvedIP)
    }

    /// Parses the first A-record IPv4 address from a DNS response packet.
    /// Returns nil if no A record is present or parsing fails.
    public static func parseFirstARecord(from data: Data, queryName: String) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 12 else { return nil }

        let ancount = (Int(bytes[6]) << 8) | Int(bytes[7])
        guard ancount > 0 else { return nil }

        // Skip question section: advance past QNAME, QTYPE, QCLASS.
        var pos = 12
        // Skip QNAME: length-prefixed labels terminated by 0x00 byte.
        // Re-check pos+1 < bytes.count before each advance to prevent a malformed
        // response from walking pos past the buffer end.
        while pos < bytes.count {
            let len = Int(bytes[pos])
            if len == 0 { pos += 1; break }
            if len & 0xC0 == 0xC0 {
                guard pos + 1 < bytes.count else { return nil }
                pos += 2; break
            }
            let next = pos + 1 + len
            guard next <= bytes.count else { return nil }
            pos = next
        }
        guard pos + 4 <= bytes.count else { return nil }
        pos += 4  // skip QTYPE + QCLASS

        // Walk answer RRs looking for an A record (type 1, class IN = 1).
        for _ in 0..<ancount {
            guard pos < bytes.count else { break }

            // Skip NAME (either inline labels or a 2-byte compression pointer).
            if pos + 1 < bytes.count && bytes[pos] & 0xC0 == 0xC0 {
                pos += 2
            } else {
                while pos < bytes.count {
                    let len = Int(bytes[pos])
                    if len == 0 { pos += 1; break }
                    if len & 0xC0 == 0xC0 {
                        guard pos + 1 < bytes.count else { return nil }
                        pos += 2; break
                    }
                    let next = pos + 1 + len
                    guard next <= bytes.count else { return nil }
                    pos = next
                }
            }

            guard pos + 10 <= bytes.count else { break }
            let rrType    = (Int(bytes[pos]) << 8) | Int(bytes[pos + 1])
            let rrClass   = (Int(bytes[pos + 2]) << 8) | Int(bytes[pos + 3])
            let rdLength  = (Int(bytes[pos + 8]) << 8) | Int(bytes[pos + 9])
            pos += 10  // past TYPE, CLASS, TTL (4 bytes), RDLENGTH

            if rrType == 1 && rrClass == 1 && rdLength == 4 && pos + 4 <= bytes.count {
                // A record: 4-byte IPv4 address in network byte order.
                let ip = "\(bytes[pos]).\(bytes[pos+1]).\(bytes[pos+2]).\(bytes[pos+3])"
                return ip
            }
            pos += rdLength
        }
        return nil
    }

    /// Returns true when `ip` is an RFC1918 private, link-local, or loopback address —
    /// any of which appearing as a DNS answer to a public hostname is a hijack signal.
    public static func isPrivateIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0], b = parts[1]
        return a == 10
            || (a == 172 && b >= 16 && b <= 31)
            || (a == 192 && b == 168)
            || (a == 169 && b == 254)
            || a == 127
    }

    /// Read the first `nameserver` entry from /etc/resolv.conf.
    /// This is what the OS uses as the system resolver. Re-read on each call
    /// because macOS rewrites /etc/resolv.conf on every network change.
    public static func systemResolverIP() -> String? {
        guard let content = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else {
            return nil
        }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("nameserver") else { continue }
            let parts = trimmed.components(separatedBy: .whitespaces)
            if parts.count >= 2 { return parts[1] }
        }
        return nil
    }

    // MARK: - Wire format

    /// Build a minimal DNS A-record query for `hostname`.
    ///
    /// Wire format:
    /// ```
    /// Header (12 bytes):
    ///   [0-1]  Transaction ID
    ///   [2-3]  Flags: 0x0100  (standard query, recursion desired)
    ///   [4-5]  QDCount: 1
    ///   [6-7]  ANCount: 0
    ///   [8-9]  NSCount: 0
    ///  [10-11] ARCount: 0
    /// Question:
    ///   QNAME: length-prefixed labels, null-terminated
    ///   QTYPE:  0x0001  (A)
    ///   QCLASS: 0x0001  (IN)
    /// ```
    public static func buildQuery(id: UInt16, hostname: String) -> Data {
        var packet = Data()

        // Header
        packet.append(UInt8(id >> 8))
        packet.append(UInt8(id & 0xFF))
        packet.append(contentsOf: [0x01, 0x00])  // flags: RD=1
        packet.append(contentsOf: [0x00, 0x01])  // QDCount = 1
        packet.append(contentsOf: [0x00, 0x00])  // ANCount = 0
        packet.append(contentsOf: [0x00, 0x00])  // NSCount = 0
        packet.append(contentsOf: [0x00, 0x00])  // ARCount = 0

        // QNAME: encode each label as length byte + ASCII bytes, terminated by 0x00
        for label in hostname.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0x00)                       // root label terminator

        // QTYPE A = 1, QCLASS IN = 1
        packet.append(contentsOf: [0x00, 0x01])  // QTYPE
        packet.append(contentsOf: [0x00, 0x01])  // QCLASS

        return packet
    }

    /// Validate a raw DNS response byte buffer.
    /// - Returns: the RCODE (0–15) if the transaction ID matches; nil otherwise.
    ///
    /// RCODE values of interest:
    ///   0 = NOERROR  (success)
    ///   2 = SERVFAIL (resolver error)
    ///   3 = NXDOMAIN (domain not found — for example.com this means a filtering resolver)
    public static func validateResponse(_ data: Data, expectedID: UInt16) -> Int? {
        guard data.count >= 12 else { return nil }
        let bytes = Array(data)

        // Transaction ID occupies bytes 0-1 (big-endian).
        let responseID = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard responseID == expectedID else { return nil }

        // RCODE is the low 4 bits of byte 3.
        let rcode = Int(bytes[3] & 0x0F)
        return rcode
    }
}

// MARK: - sockaddr helpers

private extension sockaddr_in {
    init?(ip: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        self = addr
    }
}

private extension sockaddr_in6 {
    init?(ip: String, port: UInt16) {
        var addr = sockaddr_in6()
        addr.sin6_len    = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port   = port.bigEndian
        guard inet_pton(AF_INET6, ip, &addr.sin6_addr) == 1 else { return nil }
        self = addr
    }
}
