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
            let id2      = PingTarget.defaults[1].id

            // Ensure clean state (don't pollute with UserDefaults from other tests)
            store.clearConnectionHistory()

            // Green baseline — no events
            store.record(result: PingResult(timestamp: .now, rtt: 50, lossPercent: 0, jitter: 5), for: id1)
            store.record(result: PingResult(timestamp: .now, rtt: 60, lossPercent: 0, jitter: 5), for: id2)
            expectEqual(store.connectionHistory.count, 0, "green baseline → no events")

            // Drive to yellow (2 consecutive bad polls needed due to hysteresis)
            let bad = PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5)
            store.record(result: bad, for: id1)
            expectEqual(store.connectionHistory.count, 0, "1st bad poll → still green, no event")

            store.record(result: bad, for: id1)
            expectEqual(store.overallStatus, .yellow, "2nd bad poll → yellow")
            expectEqual(store.connectionHistory.count, 1, "degradation → 1 event opened")
            expectEqual(store.connectionHistory[0].isActive, true, "event is active (not closed)")
            expectEqual(store.connectionHistory[0].severity, .yellow, "severity = yellow")

            // Recover to green — event should close
            let good = PingResult(timestamp: .now, rtt: 30, lossPercent: 0, jitter: 2)
            store.record(result: good, for: id1)
            store.record(result: good, for: id2)
            expectEqual(store.overallStatus, .green, "good poll → green")
            expectEqual(store.connectionHistory[0].isActive, false, "event closed on recovery")
            expectEqual(store.connectionHistory[0].endTime != nil, true, "endTime set on recovery")

            // Second degradation — should open a new event
            store.record(result: bad, for: id1)
            store.record(result: bad, for: id1)
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

            let good = PingResult(timestamp: .now, rtt: 30, lossPercent: 0, jitter: 2)
            let bad  = PingResult(timestamp: .now, rtt: 150, lossPercent: 0, jitter: 5)

            // Generate 6 degradation/recovery cycles
            for _ in 1...6 {
                store.record(result: good, for: id1)  // reset hysteresis
                store.record(result: bad,  for: id1)
                store.record(result: bad,  for: id1)  // opens event
                store.record(result: good, for: id1)  // closes event
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
            store.record(result: bad, for: id1)
            store.record(result: bad, for: id1)

            expectEqual(store.connectionHistory.isEmpty, false, "events present before clear")
            store.clearConnectionHistory()
            expectEqual(store.connectionHistory.isEmpty, true, "empty after clear")
        }
    }
}
