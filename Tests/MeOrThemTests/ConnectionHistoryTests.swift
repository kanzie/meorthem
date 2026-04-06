import Foundation
@testable import MeOrThemCore

func runConnectionHistoryTests() {
    suite("ConnectionEvent model") {
        let e = ConnectionEvent(severity: .yellow, startTime: Date(), cause: "high latency (145ms)")
        expectEqual(e.severity,  .yellow,          "severity round-trips through rawValue")
        expectEqual(e.isActive,  true,             "no endTime → isActive")
        expectEqual(e.cause,     "high latency (145ms)", "cause preserved")

        var closed = e
        closed.endTime = Date().addingTimeInterval(90)
        expectEqual(closed.isActive, false,        "endTime set → not active")
        // Duration: 90 s → "1m 30s"
        let dur = closed.durationString(relativeTo: closed.endTime!)
        expectEqual(dur, "1m 30s",                 "90 s → '1m 30s'")
    }

    suite("ConnectionEvent durationString edge cases") {
        MainActor.assumeIsolated {
            let start = Date()

            var e45 = ConnectionEvent(severity: .red, startTime: start, cause: "test")
            e45.endTime = start.addingTimeInterval(45)
            expectEqual(e45.durationString(relativeTo: e45.endTime!), "45s", "45 s → '45s'")

            var e60 = ConnectionEvent(severity: .red, startTime: start, cause: "test")
            e60.endTime = start.addingTimeInterval(60)
            expectEqual(e60.durationString(relativeTo: e60.endTime!), "1m", "60 s → '1m'")

            var e75 = ConnectionEvent(severity: .red, startTime: start, cause: "test")
            e75.endTime = start.addingTimeInterval(75)
            expectEqual(e75.durationString(relativeTo: e75.endTime!), "1m 15s", "75 s → '1m 15s'")
        }
    }

    suite("MetricStore connection history — green↔degraded transitions") {
        MainActor.assumeIsolated {
            let settings = AppSettings.shared
            let store    = MetricStore(settings: settings)
            let id1      = PingTarget.defaults[0].id

            store.clearConnectionHistory()

            // Default latency window = ceil(15/5) = 3 samples.
            // Seed 2 good polls so the first bad poll is diluted by the window average:
            // window = [50, 50, 150] → avg 83 ms < 100 ms yellow threshold → still green.
            let good50 = PingResult(timestamp: .now, rtt: 50,  lossPercent: 0, jitter: 5)
            let bad    = PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5)
            let good   = PingResult(timestamp: .now, rtt: 30,  lossPercent: 0, jitter: 2)

            store.record(result: good50, for: id1)
            store.record(result: good50, for: id1)
            expectEqual(store.connectionHistory.count, 0, "green baseline → no events")

            // 1st bad poll: window = [50, 50, 150] → avg 83 ms → still green
            store.record(result: bad, for: id1)
            expectEqual(store.connectionHistory.count, 0, "single bad poll diluted by window → still green, no event")

            // 2nd bad poll: window = [50, 150, 150] → avg 116 ms ≥ 100 ms → yellow
            store.record(result: bad, for: id1)
            expectEqual(store.overallStatus, .yellow, "2nd consecutive bad poll → window avg exceeds threshold → yellow")
            expectEqual(store.connectionHistory.count, 1, "degradation → 1 event opened")
            expectEqual(store.connectionHistory[0].isActive, true, "event is active (not closed)")
            expectEqual(store.connectionHistory[0].severity, .yellow, "severity = yellow")

            // Recovery: window needs to refill with good values.
            // After 1 good: window = [150, 150, 30] → avg 110 ms → still yellow
            store.record(result: good, for: id1)
            expectEqual(store.overallStatus, .yellow, "1 good poll not yet enough to recover — window still above threshold")

            // After 2 good: window = [150, 30, 30] → avg 70 ms → green
            store.record(result: good, for: id1)
            expectEqual(store.overallStatus, .green, "window refills with good samples → green")
            expectEqual(store.connectionHistory[0].isActive, false, "event closed on recovery")
            expectEqual(store.connectionHistory[0].endTime != nil, true, "endTime set on recovery")

            // Second degradation — should open a new event.
            // Re-seed window with 2 good polls, then drive bad.
            store.record(result: good50, for: id1)
            store.record(result: good50, for: id1)
            store.record(result: bad, for: id1)   // window [50, 50, 150] → avg 83 ms → green
            store.record(result: bad, for: id1)   // window [50, 150, 150] → avg 116 ms → yellow
            expectEqual(store.connectionHistory.count, 2, "second degradation → 2 events total")
            expectEqual(store.connectionHistory[0].isActive, true, "newest event is active")
            expectEqual(store.connectionHistory[1].isActive, false, "older event is closed")
        }
    }

    suite("MetricStore connection history — cap at 5 events") {
        MainActor.assumeIsolated {
            let settings = AppSettings.shared
            let store    = MetricStore(settings: settings)
            let id1      = PingTarget.defaults[0].id

            store.clearConnectionHistory()

            let good50 = PingResult(timestamp: .now, rtt: 50,  lossPercent: 0, jitter: 2)
            let bad    = PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5)
            let good   = PingResult(timestamp: .now, rtt: 30,  lossPercent: 0, jitter: 2)

            // Each cycle: seed 2 good → 1st bad (diluted) → 2nd bad (triggers yellow) →
            // 1 good (diluted) → 2 good (recovers to green).
            for _ in 1...6 {
                store.record(result: good50, for: id1)  // re-seed window
                store.record(result: good50, for: id1)
                store.record(result: bad, for: id1)     // diluted → green
                store.record(result: bad, for: id1)     // opens event → yellow
                store.record(result: good, for: id1)    // [150, 150, 30] → avg 110 ms → yellow
                store.record(result: good, for: id1)    // [150, 30, 30] → avg 70 ms → green → closes event
            }

            expectEqual(store.connectionHistory.count, 5, "history capped at 5 events")
        }
    }

    suite("MetricStore connection history — clearConnectionHistory") {
        MainActor.assumeIsolated {
            let settings = AppSettings.shared
            let store    = MetricStore(settings: settings)
            let id1      = PingTarget.defaults[0].id

            store.clearConnectionHistory()

            let bad = PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5)
            // Drive to yellow without seeding (single sample = 150 ms avg → yellow immediately)
            store.record(result: bad, for: id1)
            store.record(result: bad, for: id1)

            expectEqual(store.connectionHistory.isEmpty, false, "events present before clear")
            store.clearConnectionHistory()
            expectEqual(store.connectionHistory.isEmpty, true, "empty after clear")
        }
    }
}
