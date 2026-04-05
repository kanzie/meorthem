import Foundation
import Darwin   // for inet_pton

public enum InputValidator {

    // MARK: - Public API

    /// Returns true if input is a safe, valid hostname or IP address suitable
    /// for use as a ping target. Rejects shell metacharacters unconditionally.
    public static func isValidPingTarget(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }

        // Reject any shell metacharacter that could enable command injection
        let forbidden = CharacterSet(charactersIn: ";|&$`(){}[]<>!#\\\n\r\t\"' ")
        guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return false }

        return isIPv4(trimmed) || isIPv6(trimmed) || isHostname(trimmed)
    }

    public static func sanitizedLabel(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
             .components(separatedBy: .controlCharacters).joined()
             .prefix(64).string
    }

    // MARK: - Private helpers

    private static func isIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1
    }

    private static func isIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return inet_pton(AF_INET6, s, &addr) == 1
    }

    // RFC 1123 hostname: labels separated by dots, each 1–63 chars,
    // alphanumeric + hyphens, no leading/trailing hyphens.
    private static let hostnameLabel = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9]([A-Za-z0-9\\-]{0,61}[A-Za-z0-9])?$"
    )
    // Matches anything that looks like an IPv4 address (N.N.N.N)
    private static let ipv4Like = try! NSRegularExpression(
        pattern: "^\\d{1,5}\\.\\d{1,5}\\.\\d{1,5}\\.\\d{1,5}$"
    )

    private static func isHostname(_ s: String) -> Bool {
        // If it looks like an IPv4 address, require inet_pton to accept it.
        // Prevents "999.999.999.999" passing through as a hostname.
        let r = NSRange(s.startIndex..., in: s)
        if ipv4Like.firstMatch(in: s, range: r) != nil { return false }

        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 1 else { return false }
        return labels.allSatisfy { label in
            let str = String(label)
            guard !str.isEmpty, str.count <= 63 else { return false }
            let range = NSRange(str.startIndex..., in: str)
            return hostnameLabel.firstMatch(in: str, range: range) != nil
        }
    }
}

private extension Substring {
    var string: String { String(self) }
}

