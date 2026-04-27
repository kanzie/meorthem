import Foundation
import Darwin

/// Resolves the ISP / Autonomous System name for a public IPv4 address via DNS TXT lookups
/// against `origin.asn.cymru.com` and `asn.cymru.com`.
///
/// - All methods are blocking; call from a background thread or detached Task.
/// - Private/loopback/link-local addresses return nil immediately.
/// - Results are cached in-memory for the lifetime of the process (ISPs don't change mid-session).
public enum ASNLookup {

    // MARK: - Cache

    // nonisolated(unsafe) — access is always serialised via cacheLock.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    // MARK: - Public API

    /// Resolves the ISP org name for a public IPv4 address.
    /// Returns nil on timeout, lookup failure, private IP, or parse error.
    public static func resolve(ip: String) async -> String? {
        // Reject private/loopback/link-local ranges synchronously.
        guard isPublicIPv4(ip) else { return nil }

        // Return cached result if available (lock/unlock on calling thread is fine).
        let cached: String? = cacheLock.withLock { cache[ip] }
        if let cached { return cached }

        // Run blocking DNS queries off the caller's thread.
        let ipCopy = ip
        return await Task.detached(priority: .utility) {
            guard let asn = queryOriginASN(ip: ipCopy) else { return nil }
            guard let name = queryASNName(asn: asn) else { return nil }
            let cleaned = cleanASNName(name)
            cacheLock.withLock { cache[ipCopy] = cleaned }
            return cleaned
        }.value
    }

    // MARK: - Private range check

    static func isPublicIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        let a = parts[0], b = parts[1]
        // 10.x, 127.x, 169.254.x, 172.16–31.x, 192.168.x
        if a == 10 { return false }
        if a == 127 { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 0 { return false }
        return true
    }

    // MARK: - Cymru origin lookup

    /// Queries `{reversed-ip}.origin.asn.cymru.com` TXT and returns the ASN string.
    static func queryOriginASN(ip: String) -> String? {
        let parts = ip.split(separator: ".").reversed().joined(separator: ".")
        let hostname = "\(parts).origin.asn.cymru.com"
        guard let txt = queryTXT(hostname: hostname, resolverIP: "8.8.8.8") else { return nil }
        // Response format: "ASN | prefix | CC | registry | date"
        // e.g. "7922 | 73.0.0.0/8 | US | arin | 1998-12-01"
        let fields = txt.components(separatedBy: "|")
        return fields.first?.trimmingCharacters(in: .whitespaces)
    }

    /// Queries `AS{asn}.asn.cymru.com` TXT and returns the org name.
    static func queryASNName(asn: String) -> String? {
        let hostname = "AS\(asn).asn.cymru.com"
        guard let txt = queryTXT(hostname: hostname, resolverIP: "8.8.8.8") else { return nil }
        // Response format: "ASN | CC | registry | date | org name"
        // e.g. "7922 | US | arin | 1998-12-01 | COMCAST-7922"
        let fields = txt.components(separatedBy: "|")
        guard fields.count >= 5 else { return nil }
        return fields[4].trimmingCharacters(in: .whitespaces)
    }

    /// Removes trailing country suffix like ", US" from org names.
    private static func cleanASNName(_ name: String) -> String {
        // Some responses include country in the org field — strip it.
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // e.g. "COMCAST-7922, US" → "COMCAST-7922"
        if let comma = trimmed.lastIndex(of: ",") {
            let suffix = trimmed[trimmed.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if suffix.count == 2 && suffix.allSatisfy({ $0.isLetter && $0.isUppercase }) {
                return String(trimmed[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    // MARK: - Raw UDP TXT query

    /// Sends a DNS TXT query for `hostname` to `resolverIP:53` and returns the first TXT record's
    /// text data. Returns nil on timeout, socket error, or parse failure.
    static func queryTXT(hostname: String, resolverIP: String, timeoutSecs: Int = 3) -> String? {
        let sockFd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sockFd >= 0 else { return nil }
        defer { Darwin.close(sockFd) }

        var tv = timeval(tv_sec: timeoutSecs, tv_usec: 0)
        setsockopt(sockFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let txID = UInt16.random(in: 1...UInt16.max)
        let query = buildTXTQuery(id: txID, hostname: hostname)

        guard var addr4 = makeSockAddr(ip: resolverIP, port: 53) else { return nil }
        let connectOK = withUnsafeMutableBytes(of: &addr4) { rawBuf in
            rawBuf.withMemoryRebound(to: sockaddr.self) { saBuf in
                Darwin.connect(sockFd, saBuf.baseAddress!, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectOK == 0 else { return nil }

        let sent: Int = query.withUnsafeBytes { buf in Darwin.send(sockFd, buf.baseAddress!, buf.count, 0) }
        guard sent == query.count else { return nil }

        var response = [UInt8](repeating: 0, count: 1024)
        let received = Darwin.recv(sockFd, &response, response.count, 0)
        guard received > 12 else { return nil }

        return parseTXTResponse(Data(response.prefix(received)), expectedID: txID)
    }

    // MARK: - DNS wire format helpers

    private static func buildTXTQuery(id: UInt16, hostname: String) -> Data {
        var packet = Data()
        packet.append(UInt8(id >> 8)); packet.append(UInt8(id & 0xFF))
        packet.append(contentsOf: [0x01, 0x00]) // flags: RD=1
        packet.append(contentsOf: [0x00, 0x01]) // QDCount=1
        packet.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // AN/NS/AR=0
        for label in hostname.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0x00)                       // root
        packet.append(contentsOf: [0x00, 0x10])   // QTYPE TXT = 16
        packet.append(contentsOf: [0x00, 0x01])   // QCLASS IN = 1
        return packet
    }

    private static func makeSockAddr(ip: String, port: UInt16) -> sockaddr_in? {
        var addr = sockaddr_in()
        addr.sin_len    = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port   = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        return addr
    }

    /// Parses the first TXT RDATA string from a DNS response.
    static func parseTXTResponse(_ data: Data, expectedID: UInt16) -> String? {
        let bytes = Array(data)
        guard bytes.count >= 12 else { return nil }
        // Verify transaction ID
        let responseID = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard responseID == expectedID else { return nil }
        // RCODE must be NOERROR (0)
        guard (bytes[3] & 0x0F) == 0 else { return nil }
        // Answer count (bytes 6-7)
        let anCount = (Int(bytes[6]) << 8) | Int(bytes[7])
        guard anCount > 0 else { return nil }

        // Skip question section
        var pos = 12
        // Skip QNAME
        while pos < bytes.count {
            let len = Int(bytes[pos])
            if len == 0 { pos += 1; break }
            if len >= 0xC0 { pos += 2; break } // compressed pointer
            pos += 1 + len
        }
        pos += 4 // skip QTYPE + QCLASS

        // Read first answer record
        guard pos + 10 < bytes.count else { return nil }
        // Skip NAME (may be compressed pointer or label)
        if Int(bytes[pos]) >= 0xC0 { pos += 2 } else {
            while pos < bytes.count {
                let len = Int(bytes[pos])
                if len == 0 { pos += 1; break }
                if len >= 0xC0 { pos += 2; break }
                pos += 1 + len
            }
        }
        guard pos + 10 <= bytes.count else { return nil }
        let rtype = (Int(bytes[pos]) << 8) | Int(bytes[pos + 1]); pos += 2
        guard rtype == 16 else { return nil } // must be TXT
        pos += 6 // skip CLASS + TTL
        let rdLen = (Int(bytes[pos]) << 8) | Int(bytes[pos + 1]); pos += 2
        guard pos + rdLen <= bytes.count, rdLen > 1 else { return nil }

        // TXT RDATA: one or more character-strings, each prefixed by a length byte
        let txtLen = Int(bytes[pos])
        pos += 1
        guard pos + txtLen <= bytes.count else { return nil }
        let txtBytes = bytes[pos..<(pos + txtLen)]
        return String(bytes: txtBytes, encoding: .utf8) ?? String(bytes: txtBytes, encoding: .isoLatin1)
    }
}
