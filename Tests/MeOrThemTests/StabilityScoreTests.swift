import Foundation
import MeOrThemCore

func runStabilityScoreTests() {

    suite("ConnectionStabilityScore — perfect connection") {
        let s = ConnectionStabilityScore.compute(
            availability:  1.0,
            meanRTTMs:     10.0,
            meanLossPct:   0.0,
            meanJitterMs:  2.0
        )
        // All components at max: 40 + 25 + 25 + 10 = 100
        expectEqual(Int(s.total.rounded()), 100, "perfect score is 100")
        expectEqual(s.grade, "A", "perfect grade is A")
    }

    suite("ConnectionStabilityScore — poor connection") {
        let s = ConnectionStabilityScore.compute(
            availability:  0.70,
            meanRTTMs:     250.0,
            meanLossPct:   8.0,
            meanJitterMs:  60.0
        )
        // avail=28, lat=0, loss=0, jitter=0 → 28/100 raw → rescaled = 28
        expectEqual(Int(s.total.rounded()), 28, "poor connection scores ~28")
        expectEqual(s.grade, "F", "poor grade is F")
    }

    suite("ConnectionStabilityScore — missing components redistributed") {
        // Only availability known
        let s = ConnectionStabilityScore.compute(
            availability:  1.0,
            meanRTTMs:     nil,
            meanLossPct:   nil,
            meanJitterMs:  nil
        )
        // score=40 / weight=40 * 100 = 100
        expectEqual(Int(s.total.rounded()), 100, "full availability alone → 100 when rescaled")
    }

    suite("ConnectionStabilityScore — no data returns 0") {
        let s = ConnectionStabilityScore.compute(
            availability:  nil,
            meanRTTMs:     nil,
            meanLossPct:   nil,
            meanJitterMs:  nil
        )
        expectEqual(Int(s.total.rounded()), 0, "no data → 0")
    }

    suite("ConnectionStabilityScore — grade boundaries") {
        let grades: [(Double, String)] = [
            (95, "A"), (80, "B"), (65, "C"), (50, "D"), (30, "F")
        ]
        for (pct, expected) in grades {
            // Manufacture a score using only availability (rescales cleanly)
            let s = ConnectionStabilityScore.compute(
                availability:  pct / 100,
                meanRTTMs:     nil,
                meanLossPct:   nil,
                meanJitterMs:  nil
            )
            expectEqual(s.grade, expected, "total ~\(Int(pct)) → grade \(expected)")
        }
    }

    suite("ConnectionStabilityScore — latency thresholds") {
        let cases: [(Double, Int)] = [
            (10.0, 25), (30.0, 21), (75.0, 17), (120.0, 12), (175.0, 7), (250.0, 0)
        ]
        for (rtt, expectedPts) in cases {
            let s = ConnectionStabilityScore.compute(
                availability:  nil,
                meanRTTMs:     rtt,
                meanLossPct:   nil,
                meanJitterMs:  nil
            )
            expectEqual(Int((s.latencyPts ?? -1).rounded()), expectedPts,
                        "RTT \(Int(rtt)) ms → \(expectedPts) pts")
        }
    }
}
