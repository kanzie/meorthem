import Foundation
@testable import MeOrThemCore

func runASNLookupTests() {
    suite("ASNLookup — private IP rejection") {
        expect(!ASNLookup.isPublicIPv4("10.0.0.1"),      "10.x is private")
        expect(!ASNLookup.isPublicIPv4("10.255.255.255"), "10.255.x is private")
        expect(!ASNLookup.isPublicIPv4("172.16.0.1"),     "172.16.x is private")
        expect(!ASNLookup.isPublicIPv4("172.31.255.255"), "172.31.x is private")
        expect(!ASNLookup.isPublicIPv4("192.168.1.1"),    "192.168.x is private")
        expect(!ASNLookup.isPublicIPv4("127.0.0.1"),      "127.x is loopback")
        expect(!ASNLookup.isPublicIPv4("169.254.1.1"),    "169.254.x is link-local")
        expect(!ASNLookup.isPublicIPv4("0.0.0.0"),        "0.x is invalid")
        expect(!ASNLookup.isPublicIPv4("hostname"),       "non-IP is not public")
        expect(!ASNLookup.isPublicIPv4("2606:4700::1"),   "IPv6 is not IPv4 public")
    }

    suite("ASNLookup — public IP passes check") {
        expect(ASNLookup.isPublicIPv4("8.8.8.8"),       "Google DNS is public")
        expect(ASNLookup.isPublicIPv4("1.1.1.1"),       "Cloudflare is public")
        expect(ASNLookup.isPublicIPv4("203.0.113.1"),   "TEST-NET-3 (public range) passes")
        expect(ASNLookup.isPublicIPv4("172.15.0.1"),    "172.15 is NOT in private range")
        expect(ASNLookup.isPublicIPv4("172.32.0.1"),    "172.32 is NOT in private range")
    }

    suite("ASNLookup — TXT response parsing (synthetic)") {
        // Build a minimal valid DNS TXT response for txID=0x1234
        // with one TXT record containing "7922 | 73.0.0.0/8 | US | arin | 1998-12-01"
        let txID: UInt16 = 0x1234
        let txtContent = "7922 | 73.0.0.0/8 | US | arin | 1998-12-01"
        let txtBytes = Array(txtContent.utf8)

        var response = Data()
        // Header: txID, flags (QR+RD+RA), QDCount=1, ANCount=1, NS=0, AR=0
        response.append(UInt8(txID >> 8)); response.append(UInt8(txID & 0xFF))
        response.append(contentsOf: [0x81, 0x80])  // QR=1, RD=1, RA=1
        response.append(contentsOf: [0x00, 0x01])  // QDCount=1
        response.append(contentsOf: [0x00, 0x01])  // ANCount=1
        response.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // NS=0, AR=0

        // Question: QNAME "test" + QTYPE TXT + QCLASS IN
        response.append(contentsOf: [0x04])
        response.append(contentsOf: Array("test".utf8))
        response.append(0x00)                           // root
        response.append(contentsOf: [0x00, 0x10])       // QTYPE TXT
        response.append(contentsOf: [0x00, 0x01])       // QCLASS IN

        // Answer: compressed pointer 0xC00C → back to offset 12 (question name)
        response.append(contentsOf: [0xC0, 0x0C])       // NAME (compressed)
        response.append(contentsOf: [0x00, 0x10])       // TYPE TXT
        response.append(contentsOf: [0x00, 0x01])       // CLASS IN
        response.append(contentsOf: [0x00, 0x00, 0x00, 0x3C]) // TTL=60
        let rdLen = 1 + txtBytes.count
        response.append(UInt8(rdLen >> 8)); response.append(UInt8(rdLen & 0xFF))
        response.append(UInt8(txtBytes.count))           // TXT string length
        response.append(contentsOf: txtBytes)

        let result = ASNLookup.parseTXTResponse(response, expectedID: txID)
        expect(result != nil,                            "TXT response parsed successfully")
        expect(result == txtContent,                     "TXT content matches")
    }

    suite("ASNLookup — TXT parsing rejects wrong txID") {
        var response = Data(repeating: 0, count: 20)
        response[0] = 0x12; response[1] = 0x34  // txID = 0x1234
        response[3] = 0x80                        // QR=1, RCODE=0
        let result = ASNLookup.parseTXTResponse(response, expectedID: 0xABCD)
        expect(result == nil, "wrong txID returns nil")
    }

    suite("ASNLookup — TXT parsing rejects SERVFAIL") {
        var response = Data(repeating: 0, count: 20)
        response[0] = 0x00; response[1] = 0x01
        response[3] = 0x82  // QR=1, RCODE=2 (SERVFAIL)
        let result = ASNLookup.parseTXTResponse(response, expectedID: 0x0001)
        expect(result == nil, "SERVFAIL returns nil")
    }
}
