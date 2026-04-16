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

    suite("SQLiteStore — network sessions: open, touch, and query") {
        let store  = SQLiteStore(path: ":memory:")
        let sessID = UUID()
        let fp     = "192.168.1.1|6|2.4 GHz|192.168.1"
        let name   = "2.4 GHz • 192.168.1.x"
        let start  = Date()

        store.openSession(id: sessID, fingerprint: fp, displayName: name, startTime: start)
        store.waitForPendingOps()

        // latestSession returns the opened session
        let latest = store.latestSession(for: fp)
        expectEqual(latest != nil, true, "latestSession returns a row after openSession")
        expectEqual(latest?.id, sessID, "session ID matches")
        expectEqual(latest?.displayName, name, "display name preserved")
        expectEqual(latest?.fingerprint, fp, "fingerprint preserved")

        // Touch updates last_seen
        let touchTime = start.addingTimeInterval(60)
        store.touchSession(id: sessID, at: touchTime)
        store.waitForPendingOps()

        let touched = store.latestSession(for: fp)
        let diff = abs((touched?.lastSeen ?? start).timeIntervalSince(touchTime))
        expectEqual(diff < 1.0, true, "touchSession updates last_seen")

        // sessionsInRange returns the session when range overlaps
        let inRange = store.sessionsInRange(from: start.addingTimeInterval(-10),
                                             to: start.addingTimeInterval(120))
        expectEqual(inRange.count, 1, "sessionsInRange returns 1 session in range")

        // sessionsInRange returns nothing when range is before session start
        let outRange = store.sessionsInRange(from: start.addingTimeInterval(-100),
                                              to: start.addingTimeInterval(-10))
        expectEqual(outRange.count, 0, "sessionsInRange returns 0 when out of range")
    }

    suite("SQLiteStore — session-scoped ping and wifi rows") {
        let store   = SQLiteStore(path: ":memory:")
        let sessA   = UUID()
        let sessB   = UUID()
        let targetA = UUID()
        let now     = Date()

        // Insert pings with sessA session_id
        store.insertPing(timestamp:   now,
                         rtt:         15.0,
                         lossPercent: 0,
                         jitter:      1.0,
                         targetID:    targetA,
                         targetLabel: "T",
                         host:        "1.1.1.1",
                         sessionID:   sessA)
        store.insertPing(timestamp:   now.addingTimeInterval(5),
                         rtt:         18.0,
                         lossPercent: 0,
                         jitter:      1.5,
                         targetID:    targetA,
                         targetLabel: "T",
                         host:        "1.1.1.1",
                         sessionID:   sessA)
        // Insert one ping with a different session (sessB)
        store.insertPing(timestamp:   now.addingTimeInterval(10),
                         rtt:         200.0,
                         lossPercent: 50,
                         jitter:      20.0,
                         targetID:    targetA,
                         targetLabel: "T",
                         host:        "1.1.1.1",
                         sessionID:   sessB)
        store.waitForPendingOps()

        let rowsA = store.pingRows(for: targetA, sessionID: sessA)
        let rowsB = store.pingRows(for: targetA, sessionID: sessB)
        expectEqual(rowsA.count, 2, "2 pings for sessA")
        expectEqual(rowsB.count, 1, "1 ping for sessB")
        expectEqual(rowsA[0].rttMs, 15.0, "sessA first RTT")
        expectEqual(rowsB[0].rttMs, 200.0, "sessB RTT")

        // WiFi session-scoped rows
        let snap = WiFiSnapshot(timestamp: now, bssid: "aa:bb:cc:dd:ee:ff",
                                rssi: -60, noise: -95, snr: 35,
                                channelNumber: 36, channelBandGHz: 5.0, txRateMbps: 800,
                                interfaceName: "en0", macAddress: "aa:bb:cc:dd:ee:ff",
                                phyMode: "802.11ax", ipAddress: "192.168.1.5", routerIP: "192.168.1.1")
        store.insertWiFi(snap, sessionID: sessA)
        store.waitForPendingOps()

        let wifiA = store.wifiRows(sessionID: sessA)
        let wifiB = store.wifiRows(sessionID: sessB)
        expectEqual(wifiA.count, 1, "1 wifi row for sessA")
        expectEqual(wifiB.count, 0, "0 wifi rows for sessB")
        expectEqual(wifiA[0].rssi, -60, "wifi RSSI preserved")
    }

    suite("SQLiteStore — openSession is idempotent (INSERT OR IGNORE)") {
        let store = SQLiteStore(path: ":memory:")
        let id    = UUID()
        let fp    = "10.0.0.1|1|2.4 GHz|10.0.0"
        let t1    = Date()
        let t2    = t1.addingTimeInterval(300)

        store.openSession(id: id, fingerprint: fp, displayName: "2.4 GHz • 10.0.0.x", startTime: t1)
        store.openSession(id: id, fingerprint: fp, displayName: "2.4 GHz • 10.0.0.x", startTime: t2)
        store.waitForPendingOps()

        let sessions = store.sessionsInRange(from: t1.addingTimeInterval(-1), to: t2.addingTimeInterval(1))
        expectEqual(sessions.count, 1, "duplicate openSession inserts only one row (INSERT OR IGNORE)")
        let diff = abs(sessions[0].startedAt.timeIntervalSince(t1))
        expectEqual(diff < 1.0, true, "startedAt reflects first open, not second")
    }

    suite("SQLiteStore — DNS samples round-trip") {
        let store  = SQLiteStore(path: ":memory:")
        let sessID = UUID()
        let now    = Date()

        // Successful resolution
        store.insertDNS(timestamp: now, hostname: "dns.google",
                        resolveMs: 12.5, sessionID: sessID)
        // Failed resolution (resolveMs = nil)
        store.insertDNS(timestamp: now.addingTimeInterval(30), hostname: "dns.google",
                        resolveMs: nil, sessionID: sessID)
        // Sample from a different session — must not appear in sessID query
        let otherSession = UUID()
        store.insertDNS(timestamp: now.addingTimeInterval(60), hostname: "dns.google",
                        resolveMs: 8.0, sessionID: otherSession)
        store.waitForPendingOps()

        let rows = store.dnsRows(sessionID: sessID)
        expectEqual(rows.count, 2, "two DNS rows for sessID")
        expectEqual(rows[0].hostname, "dns.google", "hostname preserved")
        expectEqual(rows[0].resolveMs, 12.5, "resolve time preserved")
        expectNil(rows[1].resolveMs, "failed resolution stored as nil")

        let otherRows = store.dnsRows(sessionID: otherSession)
        expectEqual(otherRows.count, 1, "other session has its own row")
        expectEqual(otherRows[0].resolveMs, 8.0, "other session resolve time correct")
    }
}
