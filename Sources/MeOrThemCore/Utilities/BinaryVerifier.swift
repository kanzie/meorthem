import Foundation
import CryptoKit

public enum BinaryVerifier {
    public enum Error: Swift.Error, LocalizedError {
        case fileNotFound(String)
        case zeroByteFile(String)
        case hashMismatch(expected: String, actual: String)
        case signatureInvalid(String)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let p):        return "Binary not found at \(p)"
            case .zeroByteFile(let p):        return "Binary is empty at \(p). Download from speedtest.net/apps/cli"
            case .hashMismatch(let e, let a): return "Binary hash mismatch.\nExpected: \(e)\nActual:   \(a)"
            case .signatureInvalid(let p):    return "Binary signature invalid at \(p)"
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

    /// Verifies the binary has a valid code signature using codesign --verify.
    /// Code signing changes binary bytes, making SHA-256 checks unreliable for signed helpers.
    /// This check detects tampering at runtime regardless of which identity signed the binary.
    public static func verifySignature(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw Error.fileNotFound(path)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--deep", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw Error.signatureInvalid(path)
        }
    }
}
