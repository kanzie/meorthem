import Foundation
import MeOrThemCore   // for Process.runAsync() (Bug 15: removed duplicate from MeOrThem/Utilities)

enum PingMonitor {
    /// Pings `host` with 3 packets (200ms interval, 3s timeout) and returns raw stdout.
    /// 3 packets gives adequate loss/latency/jitter accuracy for a monitoring tool while
    /// halving subprocess duty cycle (~450ms vs ~1s), which matters at short poll intervals.
    /// Host must be pre-validated by InputValidator before calling this function.
    static func ping(host: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        // Arguments as separate array elements — no shell expansion, no injection possible
        process.arguments = ["-c", "3", "-i", "0.2", "-t", "3", host]
        let (stdout, _) = try await process.runAsync()
        return stdout
    }
}
