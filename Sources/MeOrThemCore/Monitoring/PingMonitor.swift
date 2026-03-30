import Foundation

enum PingMonitor {
    /// Pings `host` with 5 packets (200ms interval, 3s timeout) and returns raw stdout.
    /// Host must be pre-validated by InputValidator before calling this function.
    static func ping(host: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        // Arguments as separate array elements — no shell expansion, no injection possible
        process.arguments = ["-c", "5", "-i", "0.2", "-t", "3", host]
        let (stdout, _) = try await process.runAsync()
        return stdout
    }
}
