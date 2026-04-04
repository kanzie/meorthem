@testable import MeOrThemCore

func runMetricStoreTests() {
    suite("MetricStore overallStatus aggregation") {
        // MetricStore and AppSettings are @MainActor; the test runner executes on the main
        // thread so MainActor.assumeIsolated is valid here.
        MainActor.assumeIsolated {
            let settings = AppSettings.shared
            let store = MetricStore(settings: settings)
            let id1 = PingTarget.defaults[0].id
            let id2 = PingTarget.defaults[1].id

            // ── Green baseline ──────────────────────────────────────────────
            store.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 5), for: id1)
            store.record(result: PingResult(timestamp: .now, rtt: 60, lossPercent: 0, jitter: 5), for: id2)
            expectEqual(store.overallStatus, .green, "all green → overall green")

            // ── Hysteresis: yellow requires 2 consecutive bad polls ─────────
            // First bad poll: still green
            store.record(result: PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5), for: id1)
            expectEqual(store.overallStatus, .green, "1st yellow poll → still green (hysteresis)")

            // Second consecutive bad poll: escalates to yellow
            store.record(result: PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5), for: id1)
            expectEqual(store.overallStatus, .yellow, "2nd consecutive yellow poll → yellow")

            // Good poll resets hysteresis immediately
            store.record(result: PingResult(timestamp: .now, rtt: 30, lossPercent: 0, jitter: 2), for: id1)
            store.record(result: PingResult(timestamp: .now, rtt: 30, lossPercent: 0, jitter: 2), for: id2)
            expectEqual(store.overallStatus, .green, "green poll resets hysteresis")

            // ── Hysteresis: red requires 3 consecutive bad polls ────────────
            let store2 = MetricStore(settings: settings)
            let r1 = PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil) // red-level

            store2.record(result: r1, for: id1)
            expectEqual(store2.overallStatus, .green, "1st red poll → still green")
            store2.record(result: r1, for: id1)
            expectEqual(store2.overallStatus, .yellow, "2nd consecutive red poll → yellow")
            store2.record(result: r1, for: id1)
            expectEqual(store2.overallStatus, .red, "3rd consecutive red poll → red")

            // ── Loss threshold hysteresis ───────────────────────────────────
            let store3 = MetricStore(settings: settings)
            // yellow loss threshold (default 1%)
            let yellowLoss = PingResult(timestamp: .now, rtt: 50, lossPercent: 2, jitter: 2)
            store3.record(result: yellowLoss, for: id1)
            expectEqual(store3.overallStatus, .green, "1st 2% loss poll → still green")
            store3.record(result: yellowLoss, for: id1)
            expectEqual(store3.overallStatus, .yellow, "2nd consecutive 2% loss poll → yellow")

            // red loss threshold (default 3%)
            // At this point consecutiveBadCount=2 from the yellow polls above.
            // A red-level poll increments to 3, immediately satisfying the red threshold.
            let redLoss = PingResult(timestamp: .now, rtt: 50, lossPercent: 10, jitter: 2)
            store3.record(result: redLoss, for: id1)
            expectEqual(store3.overallStatus, .red, "3rd consecutive bad poll (1st red-level) → red")

            // ── rssiQuality labels ──────────────────────────────────────────
            let great = WiFiSnapshot(timestamp: .now, ssid: "T", bssid: "", rssi: -50, noise: -95, snr: 45,
                                     channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                     interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                     phyMode: "802.11ax", ipAddress: nil, routerIP: nil)
            expectEqual(great.rssiQuality, "Great",  "rssi -50 → Great")

            let good = WiFiSnapshot(timestamp: .now, ssid: "T", bssid: "", rssi: -60, noise: -95, snr: 35,
                                    channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                    interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                    phyMode: "802.11ax", ipAddress: nil, routerIP: nil)
            expectEqual(good.rssiQuality, "Good",    "rssi -60 → Good")

            let poor = WiFiSnapshot(timestamp: .now, ssid: "T", bssid: "", rssi: -72, noise: -95, snr: 23,
                                    channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                    interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                    phyMode: "802.11ax", ipAddress: nil, routerIP: nil)
            expectEqual(poor.rssiQuality, "Poor",    "rssi -72 → Poor")

            let trash = WiFiSnapshot(timestamp: .now, ssid: "T", bssid: "", rssi: -85, noise: -95, snr: 10,
                                     channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                     interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                     phyMode: "802.11ax", ipAddress: nil, routerIP: nil)
            expectEqual(trash.rssiQuality, "Trash",  "rssi -85 → Trash")

            // ── networkFaultType ────────────────────────────────────────────
            let storeF = MetricStore(settings: settings)
            // Seed with good results first
            storeF.record(result: PingResult(timestamp: .now, rtt: 20, lossPercent: 0, jitter: 1), for: id1)
            // No gateway data yet — fault type should stay .none even when degraded
            storeF.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            storeF.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            storeF.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            expectEqual(storeF.networkFaultType, .none, "no gateway data → faultType none")

            // Gateway failed → local fault
            storeF.recordGatewayPing(PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil))
            expectEqual(storeF.networkFaultType, .local, "gateway down + external down → local fault")

            // Gateway ok, all external failed → ISP
            storeF.recordGatewayPing(PingResult(timestamp: .now, rtt: 2, lossPercent: 0, jitter: 0.5))
            expectEqual(storeF.networkFaultType, .isp, "gateway up + all external down → ISP fault")
        }
    }
}
