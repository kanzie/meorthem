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
}
