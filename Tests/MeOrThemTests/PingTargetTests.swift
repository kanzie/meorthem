import Foundation
@testable import MeOrThemCore

func runPingTargetTests() {
    suite("PingTarget — ProbeMode rawValues") {
        expect(ProbeMode.icmp.rawValue  == "ICMP",  "icmp rawValue")
        expect(ProbeMode.tcp.rawValue   == "TCP",   "tcp rawValue")
        expect(ProbeMode.http.rawValue  == "HTTP",  "http rawValue")
        expect(ProbeMode.https.rawValue == "HTTPS", "https rawValue")
        expect(ProbeMode.allCases.count == 4, "4 probe modes")
    }

    suite("PingTarget — probeMode round-trip (.https)") {
        let original = PingTarget(label: "Example", host: "example.com", probeMode: .https)
        let encoder  = JSONEncoder()
        let decoder  = JSONDecoder()
        guard let data    = try? encoder.encode(original),
              let decoded = try? decoder.decode(PingTarget.self, from: data) else {
            expect(false, "encode/decode should not throw"); return
        }
        expect(decoded.probeMode == .https,         "probeMode .https preserved")
        expect(decoded.label     == "Example",      "label preserved")
        expect(decoded.host      == "example.com",  "host preserved")
    }

    suite("PingTarget — probeMode round-trip (.tcp)") {
        let original = PingTarget(label: "TCPTarget", host: "1.1.1.1", probeMode: .tcp)
        let encoder  = JSONEncoder()
        let decoder  = JSONDecoder()
        guard let data    = try? encoder.encode(original),
              let decoded = try? decoder.decode(PingTarget.self, from: data) else {
            expect(false, "encode/decode should not throw"); return
        }
        expect(decoded.probeMode == .tcp, "probeMode .tcp preserved")
    }

    suite("PingTarget — backward compat: missing probeMode key → .icmp") {
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000002","label":"Legacy","host":"8.8.8.8"}
        """.data(using: .utf8)!
        guard let decoded = try? JSONDecoder().decode(PingTarget.self, from: legacyJSON) else {
            expect(false, "decoding legacy JSON should not throw"); return
        }
        expect(decoded.probeMode == .icmp,   "default probeMode is .icmp for legacy data")
        expect(decoded.host      == "8.8.8.8", "host preserved from legacy JSON")
    }

    suite("PingTarget — default init uses .icmp") {
        let target = PingTarget(label: "X", host: "9.9.9.9")
        expect(target.probeMode == .icmp, "default probeMode is .icmp")
    }
}
