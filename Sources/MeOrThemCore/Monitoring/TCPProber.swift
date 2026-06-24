import Foundation
import os

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

        return await withCheckedContinuation { continuation in
            let done = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Double?) -> Void = { value in
                let isFirst = done.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                guard isFirst else { return }
                continuation.resume(returning: value)
            }

            // didCompleteWithError is guaranteed to fire even when readData's callback
            // is never called — happens when the NW path is unavailable and the
            // connection fails synchronously before the read handler is set up.
            let delegate = TCPProbeDelegate(onComplete: { resume(nil) })
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

            let task = session.streamTask(withHostName: host, port: port)
            task.resume()
            task.readData(ofMinLength: 0, maxLength: 0, timeout: connectTimeout) { _, _, error in
                if error != nil {
                    resume(nil)
                } else {
                    resume(Date().timeIntervalSince(start) * 1000)
                }
                session.finishTasksAndInvalidate()
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

// MARK: - Private

private final class TCPProbeDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onComplete: () -> Void

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete()
        session.finishTasksAndInvalidate()
    }
}
