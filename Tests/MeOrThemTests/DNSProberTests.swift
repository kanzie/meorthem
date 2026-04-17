import Foundation
import MeOrThemCore

// MARK: - DNSResolver model tests

func runDNSProberTests() {

    suite("DNSResolver — model defaults") {

        let defaults = DNSResolver.defaults

        expectEqual(defaults.count, 14, "14 pre-populated resolvers")

        let enabled = defaults.filter { $0.isEnabled }
        expectEqual(enabled.count, 5, "5 enabled by default (Cloudflare, Google, Quad9, System, Gateway)")

        let systemEntry = defaults.first { $0.isSystem }
        expectNotNil(systemEntry, "system resolver entry present")
        expect(systemEntry?.isEnabled == true, "system resolver enabled by default")

        let gatewayEntry = defaults.first { $0.isGateway }
        expectNotNil(gatewayEntry, "gateway resolver entry present")
        expect(gatewayEntry?.isEnabled == true, "gateway resolver enabled by default")

        // All IDs must be unique
        let ids = defaults.map { $0.id }
        expectEqual(Set(ids).count, defaults.count, "all resolver IDs are unique")

        // Static resolvers must have non-empty IPs; dynamic ones have empty IPs
        for r in defaults where !r.isSystem && !r.isGateway {
            expect(!r.ip.isEmpty, "\(r.name) has non-empty IP")
        }
        expectEqual(systemEntry?.ip, "", "system resolver has empty static IP")
        expectEqual(gatewayEntry?.ip, "", "gateway resolver has empty static IP")
    }

    suite("DNSResolver — Codable round-trip") {
        let original = DNSResolver(
            name: "Test",
            ip: "1.2.3.4",
            isEnabled: true,
            isSystem: false,
            isGateway: false,
            consecutiveFailures: 3,
            autoDisabledAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        guard let data = try? encoder.encode(original),
              let decoded = try? decoder.decode(DNSResolver.self, from: data) else {
            expect(false, "Codable encode/decode must not throw")
            return
        }
        expectEqual(decoded.id,                   original.id,                   "id round-trips")
        expectEqual(decoded.name,                  original.name,                 "name round-trips")
        expectEqual(decoded.ip,                    original.ip,                   "ip round-trips")
        expectEqual(decoded.isEnabled,             original.isEnabled,            "isEnabled round-trips")
        expectEqual(decoded.consecutiveFailures,   original.consecutiveFailures,  "consecutiveFailures round-trips")
        expectNotNil(decoded.autoDisabledAt,                                       "autoDisabledAt round-trips (non-nil)")
        expectEqual(decoded.autoDisabledAt!.timeIntervalSince1970,
                    original.autoDisabledAt!.timeIntervalSince1970,
                    "autoDisabledAt timestamp round-trips")
    }

    // MARK: - DNSProber wire format

    suite("DNSProber — buildQuery wire format") {

        let id: UInt16 = 0xABCD
        let data = DNSProber.buildQuery(id: id, hostname: "example.com")
        let bytes = Array(data)

        // Header must be 12 bytes; total for example.com:
        //   12 (header) + 1+7 (example) + 1+3 (com) + 1 (null) + 2 (QTYPE) + 2 (QCLASS) = 29
        expectEqual(bytes.count, 29, "query length for example.com is 29 bytes")

        // Transaction ID big-endian
        expectEqual(bytes[0], 0xAB, "txID high byte")
        expectEqual(bytes[1], 0xCD, "txID low byte")

        // Flags: 0x01 0x00 (standard query + RD)
        expectEqual(bytes[2], 0x01, "flags[0] = 0x01")
        expectEqual(bytes[3], 0x00, "flags[1] = 0x00")

        // QDCount = 1
        expectEqual(bytes[4], 0x00, "QDCount high = 0")
        expectEqual(bytes[5], 0x01, "QDCount low = 1")

        // Answer/Authority/Additional = 0
        expectEqual(bytes[6],  0x00, "ANCount = 0 (high)")
        expectEqual(bytes[7],  0x00, "ANCount = 0 (low)")
        expectEqual(bytes[8],  0x00, "NSCount = 0 (high)")
        expectEqual(bytes[9],  0x00, "NSCount = 0 (low)")
        expectEqual(bytes[10], 0x00, "ARCount = 0 (high)")
        expectEqual(bytes[11], 0x00, "ARCount = 0 (low)")

        // QNAME layout for "example.com":
        //   byte 12       = 0x07  (length of "example")
        //   bytes 13–19   = "example"  (7 bytes)
        //   byte 20       = 0x03  (length of "com")
        //   bytes 21–23   = "com"  (3 bytes)
        //   byte 24       = 0x00  (root label terminator)
        expectEqual(bytes[12], 0x07,                         "label length = 7 (example)")
        expectEqual(bytes[13], UInt8(ascii: "e"),            "e (first byte of example)")
        expectEqual(bytes[20], 0x03,                         "label length = 3 (com)")
        expectEqual(bytes[21], UInt8(ascii: "c"),            "c (first byte of com)")
        expectEqual(bytes[24], 0x00,                         "root label terminator")

        // QTYPE = 1 (A), QCLASS = 1 (IN)
        expectEqual(bytes[25], 0x00, "QTYPE high = 0")
        expectEqual(bytes[26], 0x01, "QTYPE low = 1 (A)")
        expectEqual(bytes[27], 0x00, "QCLASS high = 0")
        expectEqual(bytes[28], 0x01, "QCLASS low = 1 (IN)")
    }

    suite("DNSProber — validateResponse") {

        let txID: UInt16 = 0x1234

        // Craft a minimal valid response header:
        //   bytes 0-1: txID, bytes 2-3: flags (QR=1, RCODE=0), rest zeroed
        var okResponse = Data(repeating: 0, count: 12)
        okResponse[0] = 0x12   // txID high
        okResponse[1] = 0x34   // txID low
        okResponse[2] = 0x81   // flags: QR=1, OPCODE=0, AA=0, TC=0, RD=1
        okResponse[3] = 0x80   // RA=1, RCODE=0

        let rcode0 = DNSProber.validateResponse(okResponse, expectedID: txID)
        expectNotNil(rcode0, "valid response returns non-nil rcode")
        expectEqual(rcode0, 0, "RCODE=0 (NOERROR)")

        // SERVFAIL response (RCODE=2)
        var servfailResponse = okResponse
        servfailResponse[3] = 0x82   // RA=1, RCODE=2
        let rcode2 = DNSProber.validateResponse(servfailResponse, expectedID: txID)
        expectEqual(rcode2, 2, "RCODE=2 (SERVFAIL)")

        // NXDOMAIN response (RCODE=3)
        var nxResponse = okResponse
        nxResponse[3] = 0x83
        let rcode3 = DNSProber.validateResponse(nxResponse, expectedID: txID)
        expectEqual(rcode3, 3, "RCODE=3 (NXDOMAIN)")

        // Wrong transaction ID → nil
        let wrongID: UInt16 = 0xFFFF
        let rcodeWrongID = DNSProber.validateResponse(okResponse, expectedID: wrongID)
        expectNil(rcodeWrongID, "mismatched txID returns nil")

        // Too short → nil
        let shortData = Data([0x12, 0x34, 0x81])
        expectNil(DNSProber.validateResponse(shortData, expectedID: txID),
                  "response shorter than 12 bytes returns nil")

        // Empty → nil
        expectNil(DNSProber.validateResponse(Data(), expectedID: txID),
                  "empty response returns nil")
    }

    suite("DNSProber — buildQuery single-label hostname") {
        // Hostname with one label ("localhost") — verify length + structure
        let data = DNSProber.buildQuery(id: 0x0001, hostname: "localhost")
        let bytes = Array(data)
        // 12 + 1+9 + 1 + 2 + 2 = 27
        // "localhost": 12 header + 1+9 label + 1 terminator + 2 QTYPE + 2 QCLASS = 27
        // byte 12 = 0x09 (length), bytes 13-21 = "localhost", byte 22 = 0x00 terminator
        expectEqual(bytes.count, 27, "single-label query is 27 bytes")
        expectEqual(bytes[12], 0x09, "label length = 9 (localhost)")
        expectEqual(bytes[22], 0x00, "root label terminator at byte 22")
    }
}
