@testable import MeOrThemCore

func runMetricStoreTests() {
    suite("MetricStore window-based evaluation") {
        // MetricStore and AppSettings are @MainActor; the test runner executes on the main
        // thread so MainActor.assumeIsolated is valid here.
        MainActor.assumeIsolated {
            let settings = AppSettings.shared
            let id1 = PingTarget.defaults[0].id
            let id2 = PingTarget.defaults[1].id

            // Default poll=5s, latency window=15s, loss window=10s, jitter window=30s gives:
            //   latency: ceil(15/5) = 3   loss: ceil(10/5) = 2   jitter: ceil(30/5) = 6

            // ── Green baseline ──────────────────────────────────────────────
            let store = MetricStore(settings: settings)
            store.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 5), for: id1)
            store.record(result: PingResult(timestamp: .now, rtt: 60, lossPercent: 0, jitter: 5), for: id2)
            expectEqual(store.overallStatus, .green, "all green → overall green")

            // ── AWDL protection: single bad jitter in 6-sample window ───────
            // Simulates an AWDL channel scan: 5 good polls followed by 1 spike.
            // avg jitter = (5×5 + 60) / 6 ≈ 14 ms — well below the 30 ms yellow threshold.
            let storeAWDL = MetricStore(settings: settings)
            for _ in 0..<5 {
                storeAWDL.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 5), for: id1)
            }
            storeAWDL.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 60), for: id1)
            expectEqual(storeAWDL.overallStatus, .green,
                        "AWDL spike (1 bad jitter in 6-sample window) → averaged out → green")

            // ── Sustained jitter escalates correctly ────────────────────────
            let storeJ = MetricStore(settings: settings)
            for _ in 0..<6 {
                storeJ.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 60), for: id1)
            }
            // avg jitter = 60 ms >= 30 ms yellow threshold
            expectEqual(storeJ.overallStatus, .yellow, "6 consecutive bad jitter samples → yellow")

            // Red jitter sustained
            let storeJR = MetricStore(settings: settings)
            for _ in 0..<6 {
                storeJR.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 100), for: id1)
            }
            // avg jitter = 100 ms >= 80 ms red threshold
            expectEqual(storeJR.overallStatus, .red, "6 consecutive red-level jitter samples → red")

            // ── Latency window absorbs a brief spike ─────────────────────────
            // 2 good (30 ms) + 1 spike (90 ms) → avg = 150/3 = 50 ms < 60 ms yellow
            let storeLS = MetricStore(settings: settings)
            storeLS.record(result: PingResult(timestamp: .now, rtt: 30, lossPercent: 0, jitter: 5), for: id1)
            storeLS.record(result: PingResult(timestamp: .now, rtt: 30, lossPercent: 0, jitter: 5), for: id1)
            storeLS.record(result: PingResult(timestamp: .now, rtt: 90, lossPercent: 0, jitter: 5), for: id1)
            expectEqual(storeLS.overallStatus, .green, "brief latency spike in 3-sample window → averaged out → green")

            // ── Sustained latency escalates ──────────────────────────────────
            let storeL = MetricStore(settings: settings)
            for _ in 0..<3 {
                storeL.record(result: PingResult(timestamp: .now, rtt: 80, lossPercent: 0, jitter: 5), for: id1)
            }
            // avg latency = 80 ms >= 60 ms yellow threshold
            expectEqual(storeL.overallStatus, .yellow, "3 consecutive 80 ms latency samples → yellow")

            let storeLR = MetricStore(settings: settings)
            for _ in 0..<3 {
                storeLR.record(result: PingResult(timestamp: .now, rtt: 200, lossPercent: 0, jitter: 5), for: id1)
            }
            // avg latency = 200 ms >= 150 ms red threshold
            expectEqual(storeLR.overallStatus, .red, "3 consecutive 200 ms latency samples → red")

            // ── Loss window (2 samples) ──────────────────────────────────────
            // Loss window is the tightest: 2 samples. Two bad polls → alarm.
            let storeLoss = MetricStore(settings: settings)
            storeLoss.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 5), for: id1)
            storeLoss.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 5, jitter: 5), for: id1)
            // avg loss = (0 + 5) / 2 = 2.5 % >= 1 % yellow
            expectEqual(storeLoss.overallStatus, .yellow, "1 bad loss in 2-sample window → 2.5 % avg → yellow")

            let storeLoss2 = MetricStore(settings: settings)
            for _ in 0..<2 {
                storeLoss2.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 10, jitter: 5), for: id1)
            }
            // avg loss = 10 % >= 3 % red threshold
            expectEqual(storeLoss2.overallStatus, .red, "2 consecutive 10 % loss samples → red")

            // ── Timeout (100 % loss) escalates immediately ───────────────────
            let storeTimeout = MetricStore(settings: settings)
            storeTimeout.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            // avg loss = 100 % >= 3 % red threshold → red on first poll
            expectEqual(storeTimeout.overallStatus, .red, "timeout (100 % loss) → red immediately")

            // ── Recovery requires window to refill with good samples ─────────
            let storeRec = MetricStore(settings: settings)
            // Fill with 3 bad latency samples (avg 80 ms → yellow)
            for _ in 0..<3 {
                storeRec.record(result: PingResult(timestamp: .now, rtt: 80, lossPercent: 0, jitter: 5), for: id1)
            }
            expectEqual(storeRec.overallStatus, .yellow, "sustained bad latency → yellow before recovery")
            // Add 1 good poll: window = [80, 80, 40] → avg ≈ 66.7 ms → still yellow
            storeRec.record(result: PingResult(timestamp: .now, rtt: 40, lossPercent: 0, jitter: 5), for: id1)
            expectEqual(storeRec.overallStatus, .yellow, "1 good poll out of 3 still above threshold → yellow")
            // Add 2nd good poll: window = [80, 40, 40] → avg ≈ 53.3 ms → green
            storeRec.record(result: PingResult(timestamp: .now, rtt: 40, lossPercent: 0, jitter: 5), for: id1)
            expectEqual(storeRec.overallStatus, .green, "2 good polls in 3-sample latency window → avg below threshold → green")

            // ── rssiQuality labels ──────────────────────────────────────────
            let great = WiFiSnapshot(timestamp: .now, bssid: "", rssi: -50, noise: -95, snr: 45,
                                     channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                     interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                     phyMode: "802.11ax", ipAddress: nil, routerIP: nil)
            expectEqual(great.rssiQuality, "Great",  "rssi -50 → Great")

            let good = WiFiSnapshot(timestamp: .now, bssid: "", rssi: -60, noise: -95, snr: 35,
                                    channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                    interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                    phyMode: "802.11ax", ipAddress: nil, routerIP: nil)
            expectEqual(good.rssiQuality, "Good",    "rssi -60 → Good")

            let poor = WiFiSnapshot(timestamp: .now, bssid: "", rssi: -72, noise: -95, snr: 23,
                                    channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                    interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                    phyMode: "802.11ax", ipAddress: nil, routerIP: nil)
            expectEqual(poor.rssiQuality, "Poor",    "rssi -72 → Poor")

            let trash = WiFiSnapshot(timestamp: .now, bssid: "", rssi: -85, noise: -95, snr: 10,
                                     channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                     interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                     phyMode: "802.11ax", ipAddress: nil, routerIP: nil)
            expectEqual(trash.rssiQuality, "Trash",  "rssi -85 → Trash")

            // ── networkFaultType ────────────────────────────────────────────
            let storeF = MetricStore(settings: settings)
            // Seed with good result first (window will have 1 sample)
            storeF.record(result: PingResult(timestamp: .now, rtt: 20, lossPercent: 0, jitter: 1), for: id1)
            // Three full-loss polls → loss window (2 samples) fills with 100 % → red
            let fullLoss = PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil)
            storeF.record(result: fullLoss, for: id1)
            storeF.record(result: fullLoss, for: id1)
            storeF.record(result: fullLoss, for: id1)
            // No gateway data → fault type stays .none regardless of status
            expectEqual(storeF.networkFaultType, .none, "no gateway data → faultType none")

            // Gateway failed → local fault
            storeF.recordGatewayPing(PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil))
            expectEqual(storeF.networkFaultType, .local, "gateway down + external down → local fault")

            // Gateway ok, all external failed → ISP
            storeF.recordGatewayPing(PingResult(timestamp: .now, rtt: 2, lossPercent: 0, jitter: 0.5))
            expectEqual(storeF.networkFaultType, .isp, "gateway up + all external down → ISP fault")

            // ── Trimmed mean: outlier target does not dominate (3-target scenario) ──
            // id1=200ms (outlier bad), id2=50ms (good), id3=60ms (good).
            // With 2 targets the threshold behaviour stays the same (plain average).
            // We simulate 3 targets by using id1, id2, and a manual UUID for a third slot.
            let id3 = PingTarget.defaults[2].id
            let storeTrim = MetricStore(settings: settings)
            // Record 3 consecutive samples for each target to fill the latency window (3 samples).
            for _ in 0..<3 {
                storeTrim.record(result: PingResult(timestamp: .now, rtt: 200, lossPercent: 0, jitter: 5), for: id1) // outlier
                storeTrim.record(result: PingResult(timestamp: .now, rtt: 40,  lossPercent: 0, jitter: 5), for: id2) // good
                storeTrim.record(result: PingResult(timestamp: .now, rtt: 50,  lossPercent: 0, jitter: 5), for: id3) // good
            }
            // Trimmed mean discards the worst (200ms) and best (40ms), leaving 50ms → green.
            expectEqual(storeTrim.overallStatus, .green,
                        "3 targets: outlier (200ms) trimmed away → trimmed mean 50ms → green")

            // ── CPU load annotation in degradation cause ─────────────────────
            // If system load is ≥75 % when degradation starts, the cause string
            // should include "high system load (X%)".
            let storeCPU = MetricStore(settings: settings)
            // Seed 3 polls of high CPU load before triggering degradation
            storeCPU.recordSystemLoad(0.80)
            storeCPU.recordSystemLoad(0.85)
            storeCPU.recordSystemLoad(0.82)
            // Trigger degradation: 2 loss-window samples of 100 % loss → red
            storeCPU.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            storeCPU.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            // Should have opened a connection event whose cause mentions system load
            let cpuEvent = storeCPU.connectionHistory.first
            expectEqual(cpuEvent != nil, true, "degradation event created when CPU high")
            let causeContainsCPU = cpuEvent?.cause.contains("high system load") ?? false
            expectEqual(causeContainsCPU, true, "cause annotated with high system load when CPU ≥ 75%")

            // Low CPU → no annotation
            let storeLowCPU = MetricStore(settings: settings)
            storeLowCPU.recordSystemLoad(0.30)
            storeLowCPU.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            storeLowCPU.record(result: PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil), for: id1)
            let lowCPUEvent = storeLowCPU.connectionHistory.first
            let causeNoCPU = lowCPUEvent?.cause.contains("high system load") ?? true
            expectEqual(causeNoCPU, false, "cause not annotated with system load when CPU < 75%")

            // All 3 targets bad → trimmed mean still bad
            let storeAllBad = MetricStore(settings: settings)
            for _ in 0..<3 {
                storeAllBad.record(result: PingResult(timestamp: .now, rtt: 200, lossPercent: 0, jitter: 5), for: id1)
                storeAllBad.record(result: PingResult(timestamp: .now, rtt: 210, lossPercent: 0, jitter: 5), for: id2)
                storeAllBad.record(result: PingResult(timestamp: .now, rtt: 190, lossPercent: 0, jitter: 5), for: id3)
            }
            // Trimmed mean: remove 190 and 210, remaining = 200ms → red (≥150ms red threshold)
            expectEqual(storeAllBad.overallStatus, .red,
                        "3 targets all bad: trimmed mean 200ms ≥ 150ms red threshold → red")
        }
    }
}
