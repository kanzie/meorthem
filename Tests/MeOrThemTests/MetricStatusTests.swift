@testable import MeOrThemCore

func runMetricStatusTests() {
    suite("MetricStatus") {
        let t = Thresholds.default  // latencyYellow=60, latencyRed=150, lossYellow=1, lossRed=3

        let green = PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 5)
        expectEqual(MetricStatus.forPingResult(green, thresholds: t), .green, "50ms → green")

        let yellow = PingResult(timestamp: .now, rtt: 80, lossPercent: 0, jitter: 5)
        expectEqual(MetricStatus.forPingResult(yellow, thresholds: t), .yellow, "80ms → yellow")

        let red = PingResult(timestamp: .now, rtt: 400, lossPercent: 0, jitter: 5)
        expectEqual(MetricStatus.forPingResult(red, thresholds: t), .red, "400ms → red")

        let lossRed = PingResult(timestamp: .now, rtt: 20, lossPercent: 10, jitter: 2)
        expectEqual(MetricStatus.forPingResult(lossRed, thresholds: t), .red, "10% loss → red")

        let lossYellow = PingResult(timestamp: .now, rtt: 20, lossPercent: 2, jitter: 2)
        expectEqual(MetricStatus.forPingResult(lossYellow, thresholds: t), .yellow, "2% loss → yellow")

        expectEqual(MetricStatus.forPingResult(nil, thresholds: t), .red, "nil result → red")

        let timeout = PingResult(timestamp: .now, rtt: nil, lossPercent: 100, jitter: nil)
        expectEqual(MetricStatus.forPingResult(timeout, thresholds: t), .red, "timeout → red")

        expect(MetricStatus.green < .yellow, "green < yellow")
        expect(MetricStatus.yellow < .red,   "yellow < red")
        expect(MetricStatus.red > .green,    "red > green")

        let statuses: [MetricStatus] = [.green, .yellow, .green, .red, .green]
        expectEqual(statuses.max(), .red, "max of mixed = red")
    }

    suite("AppSettings evaluation window constraints") {
        MainActor.assumeIsolated {
            let s = AppSettings.shared
            let poll = s.pollIntervalSecs
            // Windows must always be ≥ poll interval (enforced by AppSettings)
            expect(s.latencyWindowSecs >= poll, "latency window ≥ poll interval")
            expect(s.lossWindowSecs    >= poll, "loss window ≥ poll interval")
            expect(s.jitterWindowSecs  >= poll, "jitter window ≥ poll interval")
            // Windows must be positive
            expect(s.latencyWindowSecs > 0, "latency window is positive")
            expect(s.lossWindowSecs    > 0, "loss window is positive")
            expect(s.jitterWindowSecs  > 0, "jitter window is positive")
        }
    }

    suite("MetricStatus.forWindow averages samples") {
        let t = Thresholds.default

        // All good → green
        expectEqual(MetricStatus.forWindow(loss: [0, 0], latency: [50, 60], jitter: [5, 8], thresholds: t), .green,
                    "avg values well below thresholds → green")

        // Single bad latency in window of 3 — avg stays below red but crosses yellow
        // (150 + 50 + 50) / 3 = 83 ms >= 60 ms yellow
        expectEqual(MetricStatus.forWindow(loss: [0], latency: [150, 50, 50], jitter: [5], thresholds: t), .yellow,
                    "one 150 ms spike averaged with two 50 ms → 83 ms avg → yellow")

        // Sustained yellow-band latency at the red boundary
        // avg = 150 ms >= 150 ms red
        expectEqual(MetricStatus.forWindow(loss: [0], latency: [150, 150, 150], jitter: [5], thresholds: t), .red,
                    "three 150 ms samples → avg 150 ms → red")

        // Sustained red latency
        // avg = 250 ms >= 150 ms red
        expectEqual(MetricStatus.forWindow(loss: [0], latency: [250, 250, 250], jitter: [5], thresholds: t), .red,
                    "three 250 ms samples → avg 250 ms → red")

        // AWDL scenario: 5 good jitter + 1 spike → avg ≈ 14 ms < 30 ms yellow
        let jitters = [Double](repeating: 5, count: 5) + [60]
        expectEqual(MetricStatus.forWindow(loss: [0], latency: [50], jitter: jitters, thresholds: t), .green,
                    "AWDL spike averaged over 6 samples → green")

        // Loss window: one bad sample in two → avg above yellow threshold
        // (0 + 5) / 2 = 2.5 % >= 1 % yellow
        expectEqual(MetricStatus.forWindow(loss: [0, 5], latency: [50], jitter: [5], thresholds: t), .yellow,
                    "avg loss 2.5 % → yellow")

        // Empty latency/jitter arrays (all timeouts) still evaluated via loss
        expectEqual(MetricStatus.forWindow(loss: [100], latency: [], jitter: [], thresholds: t), .red,
                    "100 % loss with no RTT data → red")

        // Loss takes priority over latency
        expectEqual(MetricStatus.forWindow(loss: [5], latency: [50], jitter: [5], thresholds: t), .red,
                    "loss 5 % >= red threshold takes priority over good latency")
    }

    suite("MetricStatus respects custom thresholds") {
        // Custom thresholds: latencyYellow=150ms, latencyRed=400ms, lossYellow=2%, lossRed=8%, jitterYellow=40ms, jitterRed=100ms
        var custom = Thresholds()
        custom.latencyYellowMs = 150
        custom.latencyRedMs    = 400
        custom.lossYellowPct   = 2
        custom.lossRedPct      = 8
        custom.jitterYellowMs  = 40
        custom.jitterRedMs     = 100

        // With custom thresholds, 120ms latency should be green (< 150 yellow threshold)
        let fast = PingResult(timestamp: .now, rtt: 120, lossPercent: 0, jitter: 5)
        expectEqual(MetricStatus.forPingResult(fast, thresholds: custom), .green,
                    "120ms with yellow=150ms threshold → green")

        // 200ms should be yellow (>= 150, < 400)
        let medium = PingResult(timestamp: .now, rtt: 200, lossPercent: 0, jitter: 5)
        expectEqual(MetricStatus.forPingResult(medium, thresholds: custom), .yellow,
                    "200ms with yellow=150ms red=400ms → yellow")

        // 450ms should be red (>= 400)
        let slow = PingResult(timestamp: .now, rtt: 450, lossPercent: 0, jitter: 5)
        expectEqual(MetricStatus.forPingResult(slow, thresholds: custom), .red,
                    "450ms with red=400ms → red")

        // 1.5% loss should be green with lossYellow=2%
        let lowLoss = PingResult(timestamp: .now, rtt: 50, lossPercent: 1.5, jitter: 5)
        expectEqual(MetricStatus.forPingResult(lowLoss, thresholds: custom), .green,
                    "1.5% loss with yellow=2% → green")

        // 3% loss should be yellow with lossYellow=2%, lossRed=8%
        let midLoss = PingResult(timestamp: .now, rtt: 50, lossPercent: 3, jitter: 5)
        expectEqual(MetricStatus.forPingResult(midLoss, thresholds: custom), .yellow,
                    "3% loss with yellow=2% red=8% → yellow")

        // 9% loss should be red with lossRed=8%
        let highLoss = PingResult(timestamp: .now, rtt: 50, lossPercent: 9, jitter: 5)
        expectEqual(MetricStatus.forPingResult(highLoss, thresholds: custom), .red,
                    "9% loss with red=8% → red")

        // Jitter 35ms should be green with jitterYellow=40ms
        let lowJitter = PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 35)
        expectEqual(MetricStatus.forPingResult(lowJitter, thresholds: custom), .green,
                    "35ms jitter with yellow=40ms → green")

        // Jitter 60ms should be yellow with jitterYellow=40ms, jitterRed=100ms
        let midJitter = PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 60)
        expectEqual(MetricStatus.forPingResult(midJitter, thresholds: custom), .yellow,
                    "60ms jitter with yellow=40ms red=100ms → yellow")
    }
}
