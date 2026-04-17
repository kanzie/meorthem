import Foundation

/// Runs `/usr/sbin/traceroute` and returns the raw text output.
/// Designed to be called from a detached Task — the subprocess blocks the calling thread.
enum TracerouteRunner {

    /// Maximum time (seconds) to wait for the traceroute subprocess.
    static let timeout: TimeInterval = 60

    struct Result {
        let output:   String
        let hopCount: Int?
    }

    /// Synchronously runs a traceroute to `host` and returns the result.
    /// Returns `nil` if the binary is missing or the process cannot be started.
    static func run(host: String) -> Result? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        // -n  skip reverse DNS (faster)
        // -q 1 send one probe per hop (reduces traffic)
        // -w 2 wait 2 seconds per hop (balanced between coverage and speed)
        // -m 20 maximum 20 hops
        proc.arguments = ["-n", "-q", "1", "-w", "2", "-m", "20", host]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = pipe      // capture stderr too (some hops print to stderr)

        do {
            try proc.run()
        } catch {
            return nil
        }

        // Enforce a timeout — traceroute can hang when many hops time out
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if proc.isRunning { proc.terminate() }

        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        return Result(output: output, hopCount: parseHopCount(output))
    }

    // MARK: - Private

    private static func parseHopCount(_ output: String) -> Int? {
        // Each hop line starts with its number, e.g. " 3  192.168.1.1  1.234 ms"
        // or " 3  * * *" for timeouts. The last numbered line is the hop count.
        var last: Int?
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.split(separator: " ", maxSplits: 1).first,
               let n = Int(first) {
                last = n
            }
        }
        return last
    }
}
