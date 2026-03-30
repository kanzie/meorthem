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
            let id3 = PingTarget.defaults[2].id

            // All green
            store.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 5), for: id1)
            store.record(result: PingResult(timestamp: .now, rtt: 60, lossPercent: 0, jitter: 5), for: id2)
            expectEqual(store.overallStatus, .green, "all green → overall green")

            // One yellow
            store.record(result: PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5), for: id2)
            expectEqual(store.overallStatus, .yellow, "one yellow → overall yellow")

            // One red (overrides yellow)
            store.record(result: PingResult(timestamp: .now, rtt: 400, lossPercent: 0, jitter: 5), for: id3)
            expectEqual(store.overallStatus, .red, "one red + one yellow → overall red")

            // All red via loss
            store.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            expectEqual(store.overallStatus, .red, "timeout → overall red")

            // Loss triggers yellow threshold
            let store2 = MetricStore(settings: settings)
            store2.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 2, jitter: 2), for: id1)
            expectEqual(store2.overallStatus, .yellow, "2% loss → overall yellow")

            // Loss triggers red threshold
            store2.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 10, jitter: 2), for: id1)
            expectEqual(store2.overallStatus, .red, "10% loss → overall red")

            // rssiQuality labels
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
        }
    }
}
