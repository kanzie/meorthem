@testable import MeOrThemCore
import Foundation

// Tests for the network session key / SQLiteStore session columns round-trip.
//
// Note: NetworkSessionKey itself lives in the MeOrThem app target (not Core) and
// therefore cannot be directly unit-tested here per the dual-module pattern described
// in CLAUDE.md. Instead, these tests verify the SQLiteStore-level session API —
// specifically the connection_type and weak_fingerprint columns added in v2.22.2 —
// which is the Core-side contract that NetworkSessionKey writes to.

func runNetworkSessionKeyTests() {

    suite("SQLiteStore — network session connection_type round-trip") {
        let store = SQLiteStore(path: ":memory:")
        let id    = UUID()
        let now   = Date()

        store.openSession(id: id,
                          fingerprint:     "eth|192.168.1.1|192.168.1|aa:bb:cc:dd:ee:ff",
                          displayName:     "Ethernet • 192.168.1.x",
                          connectionType:  "ethernet",
                          weakFingerprint: false,
                          startTime:       now)
        store.waitForPendingOps()

        let sessions = store.sessionsInRange(from: now.addingTimeInterval(-1),
                                              to:   now.addingTimeInterval(1))
        expectEqual(sessions.count, 1, "one session row inserted")
        expectEqual(sessions[0].connectionType, "ethernet", "connectionType persisted as 'ethernet'")
        expectEqual(sessions[0].weakFingerprint, false, "weakFingerprint false preserved")
        expectEqual(sessions[0].displayName, "Ethernet • 192.168.1.x", "displayName preserved")
        expectEqual(sessions[0].fingerprint,
                    "eth|192.168.1.1|192.168.1|aa:bb:cc:dd:ee:ff",
                    "fingerprint preserved")
    }

    suite("SQLiteStore — network session weak_fingerprint round-trip") {
        let store = SQLiteStore(path: ":memory:")
        let id    = UUID()
        let now   = Date()

        store.openSession(id: id,
                          fingerprint:     "eth|192.168.1.1|192.168.1",
                          displayName:     "Ethernet • 192.168.1.x",
                          connectionType:  "ethernet",
                          weakFingerprint: true,
                          startTime:       now)
        store.waitForPendingOps()

        let sessions = store.sessionsInRange(from: now.addingTimeInterval(-1),
                                              to:   now.addingTimeInterval(1))
        expectEqual(sessions.count, 1, "one session row inserted")
        expectEqual(sessions[0].weakFingerprint, true, "weakFingerprint true persisted")
        expectEqual(sessions[0].connectionType, "ethernet", "connectionType ethernet preserved with weak fingerprint")
    }

    suite("SQLiteStore — VPN session connection_type round-trip") {
        let store = SQLiteStore(path: ":memory:")
        let id    = UUID()
        let now   = Date()

        store.openSession(id: id,
                          fingerprint:     "vpn|utun3|10.8.0.1|10.8.0",
                          displayName:     "VPN • 10.8.0.x",
                          connectionType:  "vpn",
                          weakFingerprint: false,
                          startTime:       now)
        store.waitForPendingOps()

        let sessions = store.sessionsInRange(from: now.addingTimeInterval(-1),
                                              to:   now.addingTimeInterval(1))
        expectEqual(sessions.count, 1, "one VPN session inserted")
        expectEqual(sessions[0].connectionType, "vpn", "connectionType persisted as 'vpn'")
        expectEqual(sessions[0].weakFingerprint, false, "VPN session not marked weak")
    }

    suite("SQLiteStore — WiFi session default connection_type") {
        let store = SQLiteStore(path: ":memory:")
        let id    = UUID()
        let now   = Date()

        // Call without connectionType to verify the default is 'wifi'
        store.openSession(id: id,
                          fingerprint:  "192.168.1.1|6|2.4 GHz|192.168.1",
                          displayName:  "2.4 GHz • 192.168.1.x",
                          startTime:    now)
        store.waitForPendingOps()

        let sessions = store.sessionsInRange(from: now.addingTimeInterval(-1),
                                              to:   now.addingTimeInterval(1))
        expectEqual(sessions.count, 1, "one WiFi session inserted")
        expectEqual(sessions[0].connectionType, "wifi", "default connectionType is 'wifi'")
        expectEqual(sessions[0].weakFingerprint, false, "default weakFingerprint is false")
    }

    suite("SQLiteStore — multiple sessions in range includes all types") {
        let store = SQLiteStore(path: ":memory:")
        let base  = Date()

        let wifiID = UUID()
        let ethID  = UUID()
        let vpnID  = UUID()

        store.openSession(id: wifiID,
                          fingerprint: "192.168.1.1|6|2.4 GHz|192.168.1",
                          displayName: "2.4 GHz • 192.168.1.x",
                          connectionType: "wifi",
                          startTime: base)
        store.openSession(id: ethID,
                          fingerprint: "eth|10.0.0.1|10.0.0|aa:bb:cc:dd:ee:ff",
                          displayName: "Ethernet • 10.0.0.x",
                          connectionType: "ethernet",
                          weakFingerprint: false,
                          startTime: base.addingTimeInterval(3600))
        store.openSession(id: vpnID,
                          fingerprint: "vpn|utun2|172.16.0.1|172.16.0",
                          displayName: "VPN • 172.16.0.x",
                          connectionType: "vpn",
                          startTime: base.addingTimeInterval(7200))
        store.waitForPendingOps()

        let all = store.sessionsInRange(from: base.addingTimeInterval(-1),
                                         to:   base.addingTimeInterval(10000))
        expectEqual(all.count, 3, "three sessions in range")
        let types = Set(all.map(\.connectionType))
        expectEqual(types.contains("wifi"), true, "wifi session present")
        expectEqual(types.contains("ethernet"), true, "ethernet session present")
        expectEqual(types.contains("vpn"), true, "vpn session present")
    }
}
