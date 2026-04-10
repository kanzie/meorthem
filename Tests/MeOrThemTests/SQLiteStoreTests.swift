@testable import MeOrThemCore
import Foundation

func runSQLiteStoreTests() {
    suite("SQLiteStore — schema and inserts") {
        let store = SQLiteStore(path: ":memory:")

        // Insert one ping sample and read it back
        let targetID = UUID()
        let now = Date()
        let ping = PingResult(timestamp: now, rtt: 24.5, lossPercent: 0.0, jitter: 1.8)
        store.insertPing(ping, targetID: targetID, targetLabel: "Test", host: "1.1.1.1")
        store.waitForPendingOps()

        let rows = store.pingRows(for: targetID,
                                   from: now.addingTimeInterval(-1),
                                   to:   now.addingTimeInterval(1))
        expectEqual(rows.count, 1, "one ping row inserted")
        expectEqual(rows[0].rttMs,    24.5, "RTT preserved")
        expectEqual(rows[0].lossPct,  0.0,  "loss preserved")
        expectEqual(rows[0].jitterMs, 1.8,  "jitter preserved")

        // Timeout sample (rtt = nil, loss = 100)
        let timeout = PingResult(timestamp: now.addingTimeInterval(5), rtt: nil, lossPercent: 100.0, jitter: nil)
        store.insertPing(timeout, targetID: targetID, targetLabel: "Test", host: "1.1.1.1")
        store.waitForPendingOps()

        let rows2 = store.pingRows(for: targetID,
                                    from: now.addingTimeInterval(-1),
                                    to:   now.addingTimeInterval(10))
        expectEqual(rows2.count, 2, "two ping rows after second insert")
        expectNil(rows2[1].rttMs,    "timeout RTT is nil")
        expectNil(rows2[1].jitterMs, "timeout jitter is nil")
        expectEqual(rows2[1].lossPct, 100.0, "timeout loss is 100")

        // Raw count helper
        expectEqual(store.rawPingCount(), 2, "rawPingCount returns 2")
    }

    suite("SQLiteStore — WiFi samples") {
        let store = SQLiteStore(path: ":memory:")
        let now = Date()

        let snap = WiFiSnapshot(timestamp: now, bssid: "aa:bb:cc:dd:ee:ff",
                                rssi: -55, noise: -95, snr: 40,
                                channelNumber: 6, channelBandGHz: 2.4, txRateMbps: 300,
                                interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                phyMode: "802.11ax", ipAddress: "192.168.1.10", routerIP: "192.168.1.1")
        store.insertWiFi(snap)
        store.waitForPendingOps()

        let rows = store.wifiRows(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        expectEqual(rows.count, 1, "one WiFi row inserted")
        expectEqual(rows[0].rssi, -55, "RSSI preserved")
        expectEqual(rows[0].snr, 40, "SNR preserved")
        expectEqual(rows[0].channelNumber, 6, "channel preserved")
        expectEqual(rows[0].bandGHz, 2.4, "band preserved")
    }

    suite("SQLiteStore — incident journal") {
        let store = SQLiteStore(path: ":memory:")
        let incID = UUID()
        let start = Date()

        store.openIncident(id: incID, severity: .yellow, cause: "high latency (150ms)", startTime: start)
        store.waitForPendingOps()

        var incidents = store.recentIncidents(limit: 10)
        expectEqual(incidents.count, 1, "one incident after open")
        expectEqual(incidents[0].isActive, true, "incident is active (no end time)")
        expectEqual(incidents[0].severityRaw, 1, "severity yellow = 1")
        expectEqual(incidents[0].peakSeverityRaw, 1, "peak severity = 1 on open")

        // Escalate to red
        store.updateIncidentSeverity(id: incID, peakSeverity: .red)
        store.waitForPendingOps()

        incidents = store.recentIncidents(limit: 10)
        expectEqual(incidents[0].peakSeverityRaw, 2, "peak escalated to red = 2")

        // Close the incident
        let end = start.addingTimeInterval(90)
        store.closeIncident(id: incID, endTime: end, peakSeverity: .red)
        store.waitForPendingOps()

        incidents = store.recentIncidents(limit: 10)
        expectEqual(incidents[0].isActive, false, "incident closed after closeIncident")
        expectEqual(incidents[0].endedAt != nil, true, "endedAt is set")
    }

    suite("SQLiteStore — aggregation and pruning") {
        let store = SQLiteStore(path: ":memory:")
        let targetID = UUID()

        // Insert 3 samples well in the past (10 days ago), within the same minute
        let oldBase = Date().addingTimeInterval(-10 * 86_400)
        for i in 0..<3 {
            let r = PingResult(timestamp: oldBase.addingTimeInterval(Double(i) * 5),
                               rtt: Double(20 + i * 5), lossPercent: 0, jitter: 1.0)
            store.insertPing(r, targetID: targetID, targetLabel: "T", host: "8.8.8.8")
        }
        // Insert 1 recent sample (should survive pruning)
        let recent = PingResult(timestamp: Date(), rtt: 30, lossPercent: 0, jitter: 1.0)
        store.insertPing(recent, targetID: targetID, targetLabel: "T", host: "8.8.8.8")
        store.waitForPendingOps()

        expectEqual(store.rawPingCount(), 4, "4 raw samples before aggregation")
        expectEqual(store.aggregateCount(), 0, "0 aggregates before maintenance run")

        // Run with 7-day raw retention: 3 old samples roll up, 1 recent survives
        store.aggregateAndPrune(rawRetentionDays: 7, aggregateRetentionDays: 90, incidentRetentionDays: 365)
        store.waitForPendingOps()

        expectEqual(store.rawPingCount(), 1, "old raw samples pruned, recent survives")
        expectEqual(store.aggregateCount(), 1, "one per-minute aggregate created")

        // The aggregate's avg_rtt should be (20+25+30)/3 = 25.0
        let aggRows = store.aggregatedPingRows(for: targetID,
                                               from: oldBase.addingTimeInterval(-60),
                                               to:   oldBase.addingTimeInterval(120))
        expectEqual(aggRows.count, 1, "one aggregate row in range")
        let avgRtt = aggRows[0].rttMs ?? 0
        expectEqual(avgRtt > 24.9 && avgRtt < 25.1, true, "aggregate avg RTT ≈ 25ms")
    }

    suite("SQLiteStore — incident pruning") {
        let store = SQLiteStore(path: ":memory:")

        // Old resolved incident (2 years ago)
        let oldStart = Date().addingTimeInterval(-730 * 86_400)
        let oldEnd   = oldStart.addingTimeInterval(120)
        let oldID    = UUID()
        store.openIncident(id: oldID, severity: .red, cause: "old incident", startTime: oldStart)
        store.closeIncident(id: oldID, endTime: oldEnd, peakSeverity: .red)

        // Recent resolved incident (1 hour ago)
        let newStart = Date().addingTimeInterval(-3600)
        let newEnd   = Date().addingTimeInterval(-3500)
        let newID    = UUID()
        store.openIncident(id: newID, severity: .yellow, cause: "recent incident", startTime: newStart)
        store.closeIncident(id: newID, endTime: newEnd, peakSeverity: .yellow)
        store.waitForPendingOps()

        // Prune with 1-year incident retention
        store.aggregateAndPrune(rawRetentionDays: 7, aggregateRetentionDays: 90, incidentRetentionDays: 365)
        store.waitForPendingOps()

        let remaining = store.recentIncidents(limit: 10)
        expectEqual(remaining.count, 1, "old incident pruned, recent survives")
        expectEqual(remaining[0].cause, "recent incident", "surviving incident is the recent one")
    }

    suite("SQLiteStore — multiple targets isolation") {
        let store = SQLiteStore(path: ":memory:")
        let id1 = UUID()
        let id2 = UUID()
        let now = Date()

        store.insertPing(PingResult(timestamp: now, rtt: 10, lossPercent: 0, jitter: nil),
                         targetID: id1, targetLabel: "T1", host: "1.1.1.1")
        store.insertPing(PingResult(timestamp: now, rtt: 50, lossPercent: 5, jitter: nil),
                         targetID: id2, targetLabel: "T2", host: "8.8.8.8")
        store.waitForPendingOps()

        let rows1 = store.pingRows(for: id1, from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        let rows2 = store.pingRows(for: id2, from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        expectEqual(rows1.count, 1, "target 1 has 1 row")
        expectEqual(rows2.count, 1, "target 2 has 1 row")
        expectEqual(rows1[0].rttMs,  10.0, "T1 RTT = 10")
        expectEqual(rows2[0].rttMs,  50.0, "T2 RTT = 50")
        expectEqual(rows2[0].lossPct, 5.0, "T2 loss = 5%")
        expectEqual(store.rawPingCount(), 2, "total raw count = 2")
    }

    suite("SQLiteStore — hasPingData per-target filter") {
        let store = SQLiteStore(path: ":memory:")
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()  // target with no data
        let now = Date()

        store.insertPing(PingResult(timestamp: now, rtt: 10, lossPercent: 0, jitter: nil),
                         targetID: id1, targetLabel: "T1", host: "1.1.1.1")
        // id2: only has data 10 days in the past (simulates a target with limited history)
        let old = now.addingTimeInterval(-10 * 86_400)
        store.insertPing(PingResult(timestamp: old, rtt: 20, lossPercent: 0, jitter: nil),
                         targetID: id2, targetLabel: "T2", host: "8.8.8.8")
        store.waitForPendingOps()

        let recent = now.addingTimeInterval(-3600)  // 1h window

        // All-targets check: true because id1 has recent data
        expectEqual(store.hasPingData(from: recent, to: now), true,
                    "all-targets check finds id1 data")

        // Per-target filter: id1 has recent data
        expectEqual(store.hasPingData(forTargetIDs: [id1], from: recent, to: now), true,
                    "id1 has recent data")

        // Per-target filter: id2 has NO recent data (data is 10 days old)
        expectEqual(store.hasPingData(forTargetIDs: [id2], from: recent, to: now), false,
                    "id2 has no data in 1h window")

        // Per-target filter: id3 has no data at all
        expectEqual(store.hasPingData(forTargetIDs: [id3], from: recent, to: now), false,
                    "id3 has no data")

        // Multi-target filter: [id1, id2] → true because id1 has recent data
        expectEqual(store.hasPingData(forTargetIDs: [id1, id2], from: recent, to: now), true,
                    "[id1, id2] finds id1 data")

        // Multi-target filter: [id2, id3] → false, neither has recent data
        expectEqual(store.hasPingData(forTargetIDs: [id2, id3], from: recent, to: now), false,
                    "[id2, id3] has no recent data")

        // Empty target list falls back to all-targets check
        expectEqual(store.hasPingData(forTargetIDs: [], from: recent, to: now), true,
                    "empty list falls back to all-targets")
    }
}
