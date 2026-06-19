import Foundation
import MeOrThemCore

func runQuarantineStamperTests() {

    suite("QuarantineStamper — value format") {

        let knownDate = Date(timeIntervalSince1970: 978307200 + 0x2fe572f8) // arbitrary fixed offset
        let knownUUID = UUID(uuidString: "AABBCCDD-1234-5678-ABCD-000000000000")!
        let value = QuarantineStamper.quarantineValue(date: knownDate, uuid: knownUUID,
                                                      bundleID: "com.meorthem.app")
        let parts = value.split(separator: ";", omittingEmptySubsequences: false)

        expectEqual(parts.count, 4, "four semicolon-separated fields")
        expectEqual(String(parts[0]), "0083", "flags field is 0083")

        let ts = UInt32(max(0, knownDate.timeIntervalSince1970 - QuarantineStamper.macEpochOffset))
        let expectedHex = String(format: "%08x", ts)
        expectEqual(String(parts[1]), expectedHex, "timestamp field is hex mac-epoch seconds")

        expectEqual(String(parts[2]), "com.meorthem.app", "bundle ID field preserved")
        expectEqual(String(parts[3]), knownUUID.uuidString, "UUID field preserved")
    }

    suite("QuarantineStamper — timestamp advances with time") {
        let t1 = QuarantineStamper.quarantineValue(date: Date(timeIntervalSince1970: 1_000_000_000),
                                                   uuid: UUID(), bundleID: "x")
        let t2 = QuarantineStamper.quarantineValue(date: Date(timeIntervalSince1970: 1_000_001_000),
                                                   uuid: UUID(), bundleID: "x")
        let ts1 = t1.split(separator: ";")[1]
        let ts2 = t2.split(separator: ";")[1]
        expect(ts1 != ts2, "timestamps differ for different dates")
        let v1 = UInt32(ts1, radix: 16) ?? 0
        let v2 = UInt32(ts2, radix: 16) ?? 0
        expect(v2 > v1, "later date produces larger timestamp")
    }

    suite("QuarantineStamper — stamp writes readable xattr") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarantine_test_\(Int.random(in: 1000...9999)).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: Data([0x00]))
        defer { try? FileManager.default.removeItem(at: tmp) }

        QuarantineStamper.stamp(at: tmp)

        var buf = [CChar](repeating: 0, count: 256)
        let len = getxattr(tmp.path, "com.apple.quarantine", &buf, buf.count, 0, 0)
        expect(len > 0, "xattr was written")

        let written = String(cString: buf)
        let parts = written.split(separator: ";", omittingEmptySubsequences: false)
        expectEqual(parts.count, 4, "written xattr has four fields")
        expectEqual(String(parts[0]), "0083", "written flags are 0083")
    }
}
