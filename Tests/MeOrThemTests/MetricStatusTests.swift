@testable import MeOrThemCore

func runMetricStatusTests() {
    suite("MetricStatus") {
        let t = Thresholds.default  // latencyYellow=100, latencyRed=300, lossYellow=1, lossRed=5

        let green = PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 5)
        expectEqual(MetricStatus.forPingResult(green, thresholds: t), .green, "50ms → green")

        let yellow = PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5)
        expectEqual(MetricStatus.forPingResult(yellow, thresholds: t), .yellow, "150ms → yellow")

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

        expectEqual(MetricStatus.forRSSI(-40), .green,  "RSSI -40 → green")
        expectEqual(MetricStatus.forRSSI(-70), .yellow, "RSSI -70 → yellow")
        expectEqual(MetricStatus.forRSSI(-85), .red,    "RSSI -85 → red")
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
