import Foundation
import Darwin

public enum QuarantineStamper {
    // macOS epoch: 2001-01-01 00:00:00 UTC = 978307200 seconds after Unix epoch
    public static let macEpochOffset: TimeInterval = 978307200

    /// Builds the com.apple.quarantine xattr value in the format macOS expects:
    /// `{flags};{hex_mac_epoch};{bundle_id};{uuid}`
    /// Mirrors what Safari writes for web downloads (flags 0x0083).
    public static func quarantineValue(date: Date, uuid: UUID, bundleID: String) -> String {
        let ts = UInt32(max(0, date.timeIntervalSince1970 - macEpochOffset))
        return String(format: "0083;%08x;%@;%@", ts, bundleID, uuid.uuidString)
    }

    /// Stamps com.apple.quarantine on the file at `url` so Gatekeeper assesses
    /// its notarisation and code signature before the DMG can be mounted.
    /// Without this, URLSession downloads have no quarantine flag and bypass
    /// Gatekeeper entirely (unlike Safari downloads).
    public static func stamp(at url: URL, bundleID: String = "com.meorthem.app") {
        let value = quarantineValue(date: Date(), uuid: UUID(), bundleID: bundleID)
        value.withCString { ptr in
            _ = setxattr(url.path, "com.apple.quarantine", ptr, strlen(ptr), 0, 0)
        }
    }
}
