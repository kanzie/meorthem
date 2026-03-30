import Foundation
import CryptoKit

public enum BinaryVerifier {
    public enum Error: Swift.Error, LocalizedError {
        case fileNotFound(String)
        case zeroByteFile(String)
        case hashMismatch(expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let p):        return "Binary not found at \(p)"
            case .zeroByteFile(let p):        return "Binary is empty at \(p). Download from speedtest.net/apps/cli"
            case .hashMismatch(let e, let a): return "Binary hash mismatch.\nExpected: \(e)\nActual:   \(a)"
            }
        }
    }

    /// Returns the SHA-256 hex string of the file at path.
    public static func sha256(at path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw Error.fileNotFound(path)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else {
            throw Error.zeroByteFile(path)
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verifies the binary is non-empty and, if an expected hash is provided, matches.
    public static func verify(at path: String, expectedSHA256: String? = nil) throws {
        let actual = try sha256(at: path)
        if let expected = expectedSHA256, !expected.isEmpty {
            guard actual == expected else {
                throw Error.hashMismatch(expected: expected, actual: actual)
            }
        }
    }
}
