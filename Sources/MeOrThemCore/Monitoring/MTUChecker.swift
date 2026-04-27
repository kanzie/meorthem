import Foundation

/// Probes the effective MTU of the path to a remote host by sending a large
/// ICMP packet with the Don't-Fragment bit set (-D flag) and inspecting the
/// result.  A loss on a 1472-byte payload (1500 - 20 IP - 8 ICMP headers)
/// while normal pings succeed is a strong indicator of MTU-related fragmentation
/// or blocking.
///
/// Blocking — call from a background thread or detached Task.
public enum MTUChecker {

    public struct Result: Sendable {
        /// The probe payload size used (bytes, not including IP/ICMP headers).
        public let payloadBytes: Int
        /// `true` if the large packet reached the destination without loss.
        public let reachable: Bool
        /// Round-trip time in milliseconds if reachable, nil otherwise.
        public let rttMs: Double?
    }

    /// Probe size: 1472 bytes payload → 1500-byte Ethernet frame (20 IP + 8 ICMP).
    public static let standardPayload = 1472

    /// Send a single large-packet probe to `host` using `/sbin/ping -D`.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address to probe.
    ///   - payloadBytes: Payload size in bytes (default: 1472).
    /// - Returns: `Result` with reachability and RTT, or `nil` if the process
    ///   could not be launched.
    public static func probe(host: String, payloadBytes: Int = standardPayload) -> Result? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ping")
        // -D: set Don't-Fragment bit; -s: payload size; -c 1: single packet; -t 3: 3s timeout
        task.arguments = ["-D", "-s", "\(payloadBytes)", "-c", "1", "-t", "3", host]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        return parse(output, payloadBytes: payloadBytes)
    }

    // MARK: - Private

    private static func parse(_ output: String, payloadBytes: Int) -> Result {
        // A successful reply contains "bytes from" and "time=" in the ping output.
        let reachable = output.contains("bytes from") && output.contains("time=")
        var rttMs: Double? = nil

        if reachable, let timeRange = output.range(of: "time=") {
            let afterTime = output[timeRange.upperBound...]
            // Extract the numeric value up to the next space or " ms".
            // Trim whitespace before converting so a space between "time=" and the
            // digits (non-standard but defensive) does not silently produce nil.
            let rttString = afterTime.prefix(while: { $0.isNumber || $0 == "." })
            rttMs = Double(rttString.trimmingCharacters(in: .whitespaces))
        }

        return Result(payloadBytes: payloadBytes, reachable: reachable, rttMs: rttMs)
    }
}
