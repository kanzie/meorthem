import Foundation

/// Lightweight TCP reachability prober.
///
/// Uses URLSessionStreamTask to open a raw TCP connection to the target host
/// and port. Resolves purely at the TCP layer — no HTTP, no TLS handshake.
/// A successful connect (even immediately closed by the remote) confirms the
/// path is open; a timeout or connection-refused error means unreachable.
///
/// Typical use: call `probeAny(host:)` to try port 443 then 80 in parallel and
/// return the fastest success, or nil if both fail within the timeout.
public enum TCPProber {

    // MARK: - Configuration

    /// Default ports tried by probeAny, in order of preference.
    public static let defaultPorts: [Int] = [443, 80, 53]

    /// Timeout for each individual TCP connect attempt.
    public static let connectTimeout: TimeInterval = 3

    // MARK: - Public API

    /// Attempt a single TCP connect to host:port.
    ///
    /// - Returns: Round-trip time in milliseconds, or nil on failure/timeout.
    public static func probe(host: String, port: Int) async -> Double? {
        let start = Date()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = connectTimeout
        config.timeoutIntervalForResource = connectTimeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        return await withCheckedContinuation { continuation in
            let task = session.streamTask(withHostName: host, port: port)
            task.resume()
            // Read 0 bytes — fires as soon as the TCP connection is established
            // (or fails with an error). We never actually send or receive data.
            task.readData(ofMinLength: 0, maxLength: 0, timeout: connectTimeout) { _, _, error in
                if let _ = error {
                    continuation.resume(returning: nil)
                } else {
                    let elapsed = Date().timeIntervalSince(start) * 1000
                    continuation.resume(returning: elapsed)
                }
            }
        }
    }

    /// Try `ports` concurrently and return the RTT of the first successful connect,
    /// along with which port succeeded. Returns nil if all fail.
    public static func probeAny(host: String,
                                ports: [Int] = defaultPorts) async -> (rttMs: Double, port: Int)? {
        await withTaskGroup(of: (Double, Int)?.self) { group in
            for port in ports {
                group.addTask {
                    guard let rtt = await TCPProber.probe(host: host, port: port) else { return nil }
                    return (rtt, port)
                }
            }
            for await result in group {
                if let r = result {
                    group.cancelAll()
                    return r
                }
            }
            return nil
        }
    }
}
