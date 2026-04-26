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

    suite("SQLiteStore — interface errors round-trip") {
        let store  = SQLiteStore(path: ":memory:")
        let sessID = UUID()
        let now    = Date()

        // First delta sample with errors
        store.insertInterfaceErrors(timestamp: now, iface: "en0",
                                    errorsIn: 3, errorsOut: 1, dropsIn: 2,
                                    sessionID: sessID)
        // Second delta — only drops, no errors
        store.insertInterfaceErrors(timestamp: now.addingTimeInterval(30), iface: "en0",
                                    errorsIn: 0, errorsOut: 0, dropsIn: 5,
                                    sessionID: sessID)
        // Row from a different session — must not appear
        let otherSession = UUID()
        store.insertInterfaceErrors(timestamp: now.addingTimeInterval(60), iface: "en1",
                                    errorsIn: 7, errorsOut: 0, dropsIn: 0,
                                    sessionID: otherSession)
        store.waitForPendingOps()

        let rows = store.interfaceErrorRows(sessionID: sessID)
        expectEqual(rows.count, 2, "two interface error rows for sessID")
        expectEqual(rows[0].iface, "en0", "interface name preserved")
        expectEqual(rows[0].errorsIn, 3, "errorsIn preserved")
        expectEqual(rows[0].errorsOut, 1, "errorsOut preserved")
        expectEqual(rows[0].dropsIn, 2, "dropsIn preserved")
        expectEqual(rows[1].dropsIn, 5, "second row dropsIn correct")
        expectEqual(rows[1].errorsIn, 0, "second row errorsIn is zero")

        let otherRows = store.interfaceErrorRows(sessionID: otherSession)
        expectEqual(otherRows.count, 1, "other session has its own row")
        expectEqual(otherRows[0].iface, "en1", "other session iface correct")
        expectEqual(otherRows[0].errorsIn, 7, "other session errorsIn correct")
    }

    suite("SQLiteStore — MTU checks round-trip") {
        let store  = SQLiteStore(path: ":memory:")
        let sessID = UUID()
        let now    = Date()

        // Successful large-packet probe
        store.insertMTUCheck(timestamp: now, host: "8.8.8.8",
                             payloadBytes: 1472, reachable: true, rttMs: 14.3,
                             sessionID: sessID)
        // Failed probe (MTU issue)
        store.insertMTUCheck(timestamp: now.addingTimeInterval(150), host: "8.8.8.8",
                             payloadBytes: 1472, reachable: false, rttMs: nil,
                             sessionID: sessID)
        // Row from a different session — must not appear
        let otherSession = UUID()
        store.insertMTUCheck(timestamp: now.addingTimeInterval(300), host: "1.1.1.1",
                             payloadBytes: 1472, reachable: true, rttMs: 9.1,
                             sessionID: otherSession)
        store.waitForPendingOps()

        let rows = store.mtuRows(sessionID: sessID)
        expectEqual(rows.count, 2, "two MTU rows for sessID")
        expectEqual(rows[0].host, "8.8.8.8", "host preserved")
        expectEqual(rows[0].payloadBytes, 1472, "payloadBytes preserved")
        expect(rows[0].reachable, "first probe reachable")
        expectEqual(rows[0].rttMs, 14.3, "rttMs preserved")
        expect(!rows[1].reachable, "second probe not reachable")
        expectNil(rows[1].rttMs, "failed probe has nil rttMs")

        let otherRows = store.mtuRows(sessionID: otherSession)
        expectEqual(otherRows.count, 1, "other session has its own row")
        expectEqual(otherRows[0].host, "1.1.1.1", "other session host correct")
    }

    suite("SQLiteStore — dns_resolver_samples round-trip") {
        let store  = SQLiteStore(path: ":memory:")
        let sessID = UUID()
        let now    = Date()

        // Successful probe (NOERROR, resolveMs set)
        store.insertDNSResolverSample(timestamp: now, resolverIP: "1.1.1.1",
                                      resolverName: "Cloudflare", queryHost: "example.com",
                                      resolveMs: 12.4, rcode: 0, sessionID: sessID)
        // SERVFAIL (rcode=2, no resolveMs)
        store.insertDNSResolverSample(timestamp: now.addingTimeInterval(30), resolverIP: "8.8.8.8",
                                      resolverName: "Google", queryHost: "example.com",
                                      resolveMs: nil, rcode: 2, sessionID: sessID)
        // Timeout (nil resolveMs AND nil rcode)
        store.insertDNSResolverSample(timestamp: now.addingTimeInterval(60), resolverIP: "9.9.9.9",
                                      resolverName: "Quad9", queryHost: "example.com",
                                      resolveMs: nil, rcode: nil, sessionID: sessID)
        // Different session — must not appear in sessID query
        let otherSession = UUID()
        store.insertDNSResolverSample(timestamp: now.addingTimeInterval(90), resolverIP: "1.0.0.1",
                                      resolverName: "Cloudflare (alt)", queryHost: "example.com",
                                      resolveMs: 11.0, rcode: 0, sessionID: otherSession)
        store.waitForPendingOps()

        let rows = store.dnsResolverRows(sessionID: sessID)
        expectEqual(rows.count, 3, "three rows for sessID")

        // Row 0: Cloudflare, NOERROR
        expectEqual(rows[0].resolverIP,   "1.1.1.1",    "resolverIP preserved")
        expectEqual(rows[0].resolverName, "Cloudflare",  "resolverName preserved")
        expectEqual(rows[0].queryHost,    "example.com", "queryHost preserved")
        expectEqual(rows[0].resolveMs,    12.4,           "resolveMs preserved")
        expectEqual(rows[0].rcode,        0,              "rcode=0 (NOERROR) preserved")

        // Row 1: Google, SERVFAIL
        expectNil(rows[1].resolveMs, "SERVFAIL has nil resolveMs")
        expectEqual(rows[1].rcode,   2, "rcode=2 (SERVFAIL) preserved")

        // Row 2: Quad9, timeout
        expectNil(rows[2].resolveMs, "timeout has nil resolveMs")
        expectNil(rows[2].rcode,     "timeout has nil rcode")

        // Session isolation
        let otherRows = store.dnsResolverRows(sessionID: otherSession)
        expectEqual(otherRows.count, 1, "other session has its own row")
        expectEqual(otherRows[0].resolverIP, "1.0.0.1", "other session IP correct")

        // Time-range query: only rows 0 and 1 (within ±70 s of `now`)
        let rangeRows = store.dnsResolverRows(from: now.addingTimeInterval(-1),
                                              to:   now.addingTimeInterval(45))
        expectEqual(rangeRows.count, 2, "range query returns 2 rows")
        expectEqual(rangeRows[0].resolverIP, "1.1.1.1", "first row in range is Cloudflare")
        expectEqual(rangeRows[1].resolverIP, "8.8.8.8", "second row in range is Google")

        // Ascending order guarantee
        expect(rows[0].timestamp < rows[1].timestamp, "rows are ascending by timestamp")
    }

    suite("SQLiteStore — traceroute_events round-trip") {
        let store  = SQLiteStore(path: ":memory:")
        let sessID = UUID()
        let now    = Date()

        // Insert a successful traceroute snapshot with all fields
        store.insertTracerouteEvent(sessionID: sessID, timestamp: now,
                                    targetHost: "8.8.8.8",
                                    output: "traceroute to 8.8.8.8\n 1  192.168.1.1  1.2 ms\n 2  * * *\n 3  8.8.8.8  15.4 ms",
                                    hopCount: 3, triggerRTTMs: 120.5, triggerLossPct: 25.0)
        // Insert a timeout snapshot (nil hopCount, nil trigger values)
        store.insertTracerouteEvent(sessionID: sessID, timestamp: now.addingTimeInterval(300),
                                    targetHost: "1.1.1.1",
                                    output: "traceroute to 1.1.1.1\n 1  * * *",
                                    hopCount: nil, triggerRTTMs: nil, triggerLossPct: nil)
        // Insert an event for a different session
        let otherSess = UUID()
        store.insertTracerouteEvent(sessionID: otherSess, timestamp: now.addingTimeInterval(10),
                                    targetHost: "1.0.0.1", output: "trace...",
                                    hopCount: 5, triggerRTTMs: 50.0, triggerLossPct: 0.0)
        store.waitForPendingOps()

        let rows = store.tracerouteEvents(sessionID: sessID)
        expectEqual(rows.count, 2, "two traceroute rows for sessID")

        // First row — full data
        expectEqual(rows[0].targetHost,     "8.8.8.8", "targetHost preserved")
        expectEqual(rows[0].hopCount,        3,         "hopCount preserved")
        expectEqual(rows[0].triggerRTTMs,   120.5,      "triggerRTTMs preserved")
        expectEqual(rows[0].triggerLossPct, 25.0,       "triggerLossPct preserved")
        expect(rows[0].output.contains("192.168.1.1"),  "output text preserved")

        // Second row — nil optional fields
        expectNil(rows[1].hopCount,       "nil hopCount preserved")
        expectNil(rows[1].triggerRTTMs,   "nil triggerRTTMs preserved")
        expectNil(rows[1].triggerLossPct, "nil triggerLossPct preserved")

        // Session isolation
        let otherRows = store.tracerouteEvents(sessionID: otherSess)
        expectEqual(otherRows.count, 1, "other session has its own row")
        expectEqual(otherRows[0].targetHost, "1.0.0.1", "other session host correct")

        // Ascending order
        expect(rows[0].timestamp < rows[1].timestamp, "rows ascending by timestamp")
    }

    suite("SQLiteStore — hourlyRTTAverages") {
        let store = SQLiteStore(path: ":memory:")
        // Use timestamps 10 days in the past so aggregateAndPrune picks them up
        // (raw retention = 7 days; anything older gets aggregated and pruned)
        let base = Date().addingTimeInterval(-10 * 86_400)
        let tID  = UUID()

        // Group A: 5 pings one minute apart — RTT ~80 ms
        for i in 0..<5 {
            let ts = base.addingTimeInterval(Double(i) * 60)
            let p  = PingResult(timestamp: ts, rtt: 80.0 + Double(i), lossPercent: 0, jitter: nil)
            store.insertPing(p, targetID: tID, targetLabel: "T", host: "h")
        }
        // Group B: 4 pings starting 2 hours later — RTT ~200 ms
        // 2-hour offset guarantees a different hour-of-day bucket regardless of timezone
        for i in 0..<4 {
            let ts = base.addingTimeInterval(7200 + Double(i) * 60)
            let p  = PingResult(timestamp: ts, rtt: 200.0 + Double(i), lossPercent: 0, jitter: nil)
            store.insertPing(p, targetID: tID, targetLabel: "T", host: "h")
        }
        store.waitForPendingOps()

        // Aggregate: moves old ping_samples into ping_aggregates
        store.aggregateAndPrune(rawRetentionDays: 7, aggregateRetentionDays: 90, incidentRetentionDays: 365)
        store.waitForPendingOps()

        // Query with 20-day lookback and minSampleCount=1
        let averages = store.hourlyRTTAverages(lookback: 20 * 86_400, minSampleCount: 1)

        // Must see at least 2 distinct hour buckets (group A and group B are 2 h apart)
        expect(averages.count >= 2, "at least 2 hour buckets found")

        // The higher-RTT group's hour must be measurably worse
        let rtts = averages.values.sorted()
        if rtts.count >= 2 {
            expect(rtts.last! > rtts.first! * 1.5,
                   "high-RTT hour is significantly worse than low-RTT hour")
        }

        // minSampleCount filter: require more aggregate rows than any hour has
        let filtered = store.hourlyRTTAverages(lookback: 20 * 86_400, minSampleCount: 50)
        expect(filtered.isEmpty, "high minSampleCount filters all sparse hours")
    }

    suite("SQLiteStore — allIncidentRows and incidentRows(from:to:)") {
        let store = SQLiteStore(path: ":memory:")
        let now   = Date()

        // Insert 3 incidents at different times
        let ids   = [UUID(), UUID(), UUID()]
        let times = [now.addingTimeInterval(-7200), now.addingTimeInterval(-3600), now]
        for (i, (id, ts)) in zip(ids, times).enumerated() {
            store.openIncident(id: id, severity: i == 2 ? .red : .yellow,
                               cause: "incident \(i)", startTime: ts)
        }
        store.closeIncident(id: ids[0], endTime: times[0].addingTimeInterval(120), peakSeverity: .yellow)
        store.closeIncident(id: ids[1], endTime: times[1].addingTimeInterval(60),  peakSeverity: .yellow)
        store.waitForPendingOps()

        // allIncidentRows returns all 3, newest first
        let all = store.allIncidentRows(limit: 500)
        expectEqual(all.count, 3, "allIncidentRows returns all 3 incidents")
        expectEqual(all[0].cause, "incident 2", "newest incident is first")
        expectEqual(all[2].cause, "incident 0", "oldest incident is last")

        // incidentRows(from:to:) filters by start time
        let ranged = store.incidentRows(from: now.addingTimeInterval(-4000),
                                         to:   now.addingTimeInterval(-2000))
        expectEqual(ranged.count, 1, "range query returns only incident at -3600s")
        expectEqual(ranged[0].cause, "incident 1", "correct incident in range")

        // Open incident (no endedAt) is included
        let openInc = all.first { $0.isActive }
        expectEqual(openInc != nil, true, "open incident present in allIncidentRows")
        expectEqual(openInc?.cause, "incident 2", "open incident is the red one")
    }

    suite("SQLiteStore — speedtest rows round-trip") {
        let store = SQLiteStore(path: ":memory:")
        let now   = Date()

        // Insert 5 speedtest results at 1-hour intervals
        for i in 0..<5 {
            let ts = now.addingTimeInterval(Double(i) * 3600)
            store.insertSpeedtest(timestamp:    ts,
                                  downloadMbps: Double(100 + i * 10),
                                  uploadMbps:   Double(20 + i * 5),
                                  latencyMs:    Double(15 + i),
                                  jitterMs:     Double(2 + i),
                                  isp:          "TestISP",
                                  serverName:   "test-server-\(i)")
        }
        store.waitForPendingOps()

        // Full range query returns all 5 rows
        let from = now.addingTimeInterval(-1)
        let to   = now.addingTimeInterval(5 * 3600 + 1)
        let rows = store.speedtestRows(from: from, to: to)
        expectEqual(rows.count, 5, "speedtestRows returns all 5 rows")

        // Fields are preserved on first row
        expectEqual(rows[0].downloadMbps, 100.0, "download Mbps preserved")
        expectEqual(rows[0].uploadMbps,   20.0,  "upload Mbps preserved")
        expectEqual(rows[0].latencyMs,    15.0,  "latency ms preserved")
        expectEqual(rows[0].jitterMs,     2.0,   "jitter ms preserved")
        expectEqual(rows[0].isp,          "TestISP", "ISP preserved")
        expectEqual(rows[0].serverName,   "test-server-0", "server name preserved")

        // Last row has incremented values
        expectEqual(rows[4].downloadMbps, 140.0, "last row download Mbps")
        expectEqual(rows[4].uploadMbps,   40.0,  "last row upload Mbps")

        // Ascending order by timestamp
        expect(rows[0].timestamp < rows[4].timestamp, "rows ascending by timestamp")

        // Narrow range returns subset: rows at 1h and 2h offsets
        let narrowRows = store.speedtestRows(from: now.addingTimeInterval(1800),
                                              to:   now.addingTimeInterval(9000))
        expectEqual(narrowRows.count, 2, "narrow range returns 2 rows (index 1 and 2)")
        expectEqual(narrowRows[0].downloadMbps, 110.0, "first in narrow range has correct Mbps")
    }

    suite("SQLiteStore — connection profile upsert and read") {
        let store = SQLiteStore(path: ":memory:")
        let fp    = "wifi|192.168.1.1|6|2.4|192.168.1"
        let name  = "Home WiFi"

        store.upsertConnectionProfile(fingerprint: fp, displayName: name)
        store.waitForPendingOps()

        let profile = store.connectionProfile(fingerprint: fp)
        expectEqual(profile != nil,            true,  "profile exists after upsert")
        expectEqual(profile?.fingerprint,      fp,    "fingerprint preserved")
        expectEqual(profile?.displayName,      name,  "displayName preserved")
        expectEqual(profile?.stealthMode,      false, "stealthMode defaults to false")
        expectEqual(profile?.icmpThrottled,    false, "icmpThrottled defaults to false")
        expectEqual(profile?.totalSessions,    1,     "totalSessions starts at 1")
        expectEqual(profile?.stealthProbePort, nil,   "stealthProbePort nil by default")
        expectEqual(profile?.stealthDetectedAt, nil,  "stealthDetectedAt nil by default")

        // Second upsert increments totalSessions
        store.upsertConnectionProfile(fingerprint: fp, displayName: name)
        store.waitForPendingOps()
        let profile2 = store.connectionProfile(fingerprint: fp)
        expectEqual(profile2?.totalSessions, 2, "totalSessions increments on re-upsert")
    }

    suite("SQLiteStore — connection profile stealth mode CRUD") {
        let store = SQLiteStore(path: ":memory:")
        let fp    = "wifi|10.0.0.1|1|5.0|10.0.0"
        store.upsertConnectionProfile(fingerprint: fp, displayName: "Office")
        store.waitForPendingOps()

        // Enable stealth mode
        store.setStealthMode(true, probePort: 443, source: "auto", fingerprint: fp)
        store.waitForPendingOps()
        let stealthOn = store.connectionProfile(fingerprint: fp)
        expectEqual(stealthOn?.stealthMode,              true,   "stealth mode enabled")
        expectEqual(stealthOn?.stealthProbePort,         443,    "probe port stored")
        expectEqual(stealthOn?.stealthSource,            "auto", "source stored")
        expectEqual(stealthOn?.stealthDetectedAt != nil, true,   "detectedAt set when enabling")

        // Mark ICMP throttled
        store.setICMPThrottled(true, fingerprint: fp)
        store.waitForPendingOps()
        let throttled = store.connectionProfile(fingerprint: fp)
        expectEqual(throttled?.icmpThrottled,          true, "icmpThrottled set to true")
        expectEqual(throttled?.icmpThrottledAt != nil, true, "icmpThrottledAt set")

        // Update ICMP last-ok
        store.updateICMPLastOk(fingerprint: fp)
        store.waitForPendingOps()
        let withOk = store.connectionProfile(fingerprint: fp)
        expectEqual(withOk?.icmpLastOkAt != nil, true, "icmpLastOkAt updated")

        // Disable stealth mode
        store.setStealthMode(false, probePort: nil, source: nil, fingerprint: fp)
        store.waitForPendingOps()
        let stealthOff = store.connectionProfile(fingerprint: fp)
        expectEqual(stealthOff?.stealthMode,      false, "stealth mode disabled")
        expectEqual(stealthOff?.stealthDetectedAt, nil,  "detectedAt cleared on disable")
    }

    suite("SQLiteStore — allConnectionProfiles returns all rows") {
        let store = SQLiteStore(path: ":memory:")
        store.upsertConnectionProfile(fingerprint: "fp-A", displayName: "Network A")
        store.upsertConnectionProfile(fingerprint: "fp-B", displayName: "Network B")
        store.upsertConnectionProfile(fingerprint: "fp-C", displayName: "Network C")
        store.waitForPendingOps()

        let all = store.allConnectionProfiles()
        expectEqual(all.count, 3, "allConnectionProfiles returns all 3 profiles")
        let names = all.map(\.displayName)
        expectEqual(names.contains("Network A"), true, "Network A present")
        expectEqual(names.contains("Network B"), true, "Network B present")
        expectEqual(names.contains("Network C"), true, "Network C present")
    }

    suite("SQLiteStore — preferredPollInterval CRUD") {
        let store = SQLiteStore(path: ":memory:")
        let fp = "eth|00:11:22:33:44:55|192.168.0.1|192.168.0"
        store.upsertConnectionProfile(fingerprint: fp, displayName: "Ethernet")
        store.setPreferredPollInterval(2.0, source: "user", fingerprint: fp)
        store.waitForPendingOps()

        let p = store.connectionProfile(fingerprint: fp)
        expectEqual(p?.preferredPollInterval, 2.0,   "preferredPollInterval stored")
        expectEqual(p?.pollIntervalSource,    "user", "pollIntervalSource stored")

        // Clear it
        store.setPreferredPollInterval(nil, source: nil, fingerprint: fp)
        store.waitForPendingOps()
        let p2 = store.connectionProfile(fingerprint: fp)
        expectEqual(p2?.preferredPollInterval, nil, "preferredPollInterval cleared")
        expectEqual(p2?.pollIntervalSource,    nil, "pollIntervalSource cleared")
    }

    suite("SQLiteStore — network_sessions vpn_interface column") {
        let store = SQLiteStore(path: ":memory:")
        let sid = UUID()
        let fp  = "vpn|utun3|10.8.0.1|10.8.0"

        // Open session with VPN interface
        store.openSession(id: sid, fingerprint: fp, displayName: "VPN • 10.8.0.x",
                          connectionType: "vpn", vpnInterface: "utun3")
        store.waitForPendingOps()

        // Verify vpn_interface is stored and returned
        let row = store.sessionsInRange(from: Date.distantPast, to: Date.distantFuture).first
        expectEqual(row?.vpnInterface, "utun3", "vpn_interface stored on session open")

        // Open session without VPN interface — should be nil
        let sid2 = UUID()
        let fp2  = "wifi|ch6|2.4 GHz|192.168.1"
        store.openSession(id: sid2, fingerprint: fp2, displayName: "2.4 GHz • 192.168.1.x")
        store.waitForPendingOps()

        let rows = store.sessionsInRange(from: Date.distantPast, to: Date.distantFuture)
        let wifiRow = rows.first(where: { $0.fingerprint == fp2 })
        expectEqual(wifiRow?.vpnInterface, nil, "vpn_interface nil when no VPN")
    }

    suite("SQLiteStore — system_events table round-trip") {
        let store = SQLiteStore(path: ":memory:")
        let now   = Date()
        let sleep = now.addingTimeInterval(-60)
        let wake  = now.addingTimeInterval(-30)

        store.insertSystemEvent(timestamp: sleep, eventType: "sleep")
        store.insertSystemEvent(timestamp: wake,  eventType: "wake")
        store.waitForPendingOps()

        let rows = store.systemEventRows(from: now.addingTimeInterval(-120), to: now)
        expectEqual(rows.count, 2, "two system events stored")
        expectEqual(rows[0].eventType, "sleep", "first event is sleep")
        expectEqual(rows[1].eventType, "wake",  "second event is wake")

        // Query with narrower range — only wake event should be returned
        let narrow = store.systemEventRows(from: now.addingTimeInterval(-45), to: now)
        expectEqual(narrow.count, 1, "narrow range returns only wake event")
        expectEqual(narrow[0].eventType, "wake", "narrow range event is wake")
    }

    suite("SQLiteStore — system_events table created in schema") {
        let store = SQLiteStore(path: ":memory:")
        // If the table doesn't exist, insertSystemEvent would crash; this confirms schema.
        store.insertSystemEvent(timestamp: Date(), eventType: "wake")
        store.waitForPendingOps()
        let rows = store.systemEventRows(from: Date.distantPast, to: Date.distantFuture)
        expectEqual(rows.count, 1, "system_events table exists and accepts rows")
    }

    suite("SQLiteStore — availabilityFraction basic calculation") {
        let store = SQLiteStore(path: ":memory:")
        let base  = Date(timeIntervalSince1970: 1_700_000_000)
        let window: TimeInterval = 86_400  // 24 hours

        // Insert a 10-minute incident within the window
        let incID = UUID()
        let incStart = base.addingTimeInterval(3600)        // 1h in
        let incEnd   = incStart.addingTimeInterval(600)     // 10 minutes long

        store.openIncident(id: incID, severityRaw: 2, cause: "test", startTime: incStart)
        store.waitForPendingOps()
        store.closeIncident(id: incID, endTime: incEnd, peakSeverityRaw: 2)
        store.waitForPendingOps()

        let result = store.availabilityFraction(from: base, to: base.addingTimeInterval(window))
        guard let avail = result else {
            expectEqual(false, true, "availabilityFraction should not be nil with incident data")
            return
        }

        // Expected: 1 - 600/86400 ≈ 0.993056
        let expected = 1.0 - 600.0 / 86_400.0
        expectEqual(abs(avail - expected) < 0.0001, true, "availability matches expected fraction")
    }

    suite("SQLiteStore — availabilityFraction overlapping incidents merged") {
        let store = SQLiteStore(path: ":memory:")
        let base  = Date(timeIntervalSince1970: 1_700_000_000)

        // Two overlapping incidents: total unique degraded time = 15 minutes (not 20)
        let id1 = UUID(); let id2 = UUID()
        let s1 = base.addingTimeInterval(3600); let e1 = s1.addingTimeInterval(600)  // 10min
        let s2 = base.addingTimeInterval(4000); let e2 = s2.addingTimeInterval(500)  // overlaps, +5min unique

        store.openIncident(id: id1, severityRaw: 2, cause: "a", startTime: s1)
        store.waitForPendingOps()
        store.closeIncident(id: id1, endTime: e1, peakSeverityRaw: 2)
        store.waitForPendingOps()
        store.openIncident(id: id2, severityRaw: 2, cause: "b", startTime: s2)
        store.waitForPendingOps()
        store.closeIncident(id: id2, endTime: e2, peakSeverityRaw: 2)
        store.waitForPendingOps()

        let window: TimeInterval = 86_400
        let result = store.availabilityFraction(from: base, to: base.addingTimeInterval(window))
        guard let avail = result else {
            expectEqual(false, true, "should return non-nil availability")
            return
        }

        // Unique degraded: from s1 to max(e1, e2) = s1 to e2 = 3600 to 4500 = 900s
        let uniqueDegraded = e2.timeIntervalSince(s1)  // 900s
        let expected = 1.0 - uniqueDegraded / window
        expectEqual(abs(avail - expected) < 0.0001, true, "overlapping incidents merged correctly")
    }

    suite("SQLiteStore — availabilityFraction returns nil with no incidents") {
        let store = SQLiteStore(path: ":memory:")
        let base  = Date(timeIntervalSince1970: 1_700_000_000)
        let result = store.availabilityFraction(from: base, to: base.addingTimeInterval(86_400))
        expectEqual(result, nil, "nil when no incidents in range")
    }
}
