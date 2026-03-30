@testable import MeOrThemCore

func runSpeedtestParserTests() {
    suite("SpeedtestParser") {
        let normal = """
        {
          "download": { "bandwidth": 12500000 },
          "upload":   { "bandwidth": 6250000 },
          "ping":     { "latency": 12.345, "jitter": 1.234 },
          "isp":      "Test ISP",
          "server":   { "name": "Dallas, TX" }
        }
        """
        expectNoThrow("valid JSON parses") {
            let r = try SpeedtestParser.parse(normal)
            expect(abs(r.downloadMbps - 100.0) < 0.01, "download 100 Mbps")
            expect(abs(r.uploadMbps   -  50.0) < 0.01, "upload 50 Mbps")
            expect(abs(r.latencyMs   - 12.345) < 0.001, "latency 12.345 ms")
            expectEqual(r.isp, "Test ISP", "ISP name")
            expectEqual(r.serverName, "Dallas, TX", "server name")
        }

        expectThrows("missing bandwidth throws") {
            _ = try SpeedtestParser.parse(#"{ "ping": { "latency": 10.0 } }"#)
        }

        expectThrows("invalid JSON throws") {
            _ = try SpeedtestParser.parse("not json at all")
        }

        expectNoThrow("missing optional fields use defaults") {
            let r = try SpeedtestParser.parse("""
            { "download": { "bandwidth": 1000000 }, "upload": { "bandwidth": 500000 } }
            """)
            expectEqual(r.latencyMs, 0, "default latency 0")
            expectEqual(r.isp, "Unknown", "default ISP")
        }
    }
}
