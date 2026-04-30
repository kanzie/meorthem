import Foundation

/// Reads hardware-level packet error and drop counters for a named network interface.
/// Interface errors at the driver level (as opposed to TCP retransmissions) indicate
/// RF interference, hardware faults, or driver buffer overflows.
/// Blocking — call from a background thread or detached Task.
public enum InterfaceMonitor {

    public struct Counters: Sendable {
        public let iface: String
        public let errorsIn:  UInt64   // cumulative input (receive) errors
        public let errorsOut: UInt64   // cumulative output (transmit) errors
        public let dropsIn:   UInt64   // cumulative input drops (driver buffer full)
        public let packetsIn: UInt64   // cumulative input packets
    }

    /// Read cumulative interface counters for the named interface via `netstat -i -n`.
    /// Returns `nil` if the interface is not found or the process cannot be launched.
    public static func readCounters(for interfaceName: String) -> Counters? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-i", "-n"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
        } catch { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        return parse(output, interface: interfaceName)
    }

    // MARK: - Private

    private static func parse(_ output: String, interface iface: String) -> Counters? {
        let lines = output.components(separatedBy: "\n")
        // First line is the header — parse column names to find indices dynamically.
        guard let header = lines.first else { return nil }
        let headers = header.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        func colIndex(_ name: String) -> Int? { headers.firstIndex(of: name) }

        // Required columns
        guard let ipktsCol = colIndex("Ipkts"),
              let ierrsCol = colIndex("Ierrs") else { return nil }
        let oerrsCol = colIndex("Oerrs")
        let idropCol = colIndex("Idrop")   // not present on all macOS versions

        for line in lines.dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Match the AF_LINK row: first column = interface name, third column contains "Link"
            guard parts.count > ierrsCol,
                  parts[0] == iface,
                  parts.count > 2, parts[2].contains("Link") else { continue }

            let pktsIn   = ipktsCol < parts.count ? UInt64(parts[ipktsCol]) ?? 0 : 0
            let errsIn   = ierrsCol < parts.count ? UInt64(parts[ierrsCol]) ?? 0 : 0
            let errsOut  = oerrsCol.flatMap { $0 < parts.count ? UInt64(parts[$0]) : nil } ?? 0
            let dropsIn  = idropCol.flatMap { $0 < parts.count ? UInt64(parts[$0]) : nil } ?? 0

            return Counters(iface: iface, errorsIn: errsIn, errorsOut: errsOut,
                            dropsIn: dropsIn, packetsIn: pktsIn)
        }
        return nil
    }
}
