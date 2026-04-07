import Darwin

/// Samples system-wide CPU utilisation using Mach host statistics.
///
/// Call `sample()` once per poll tick. Each call returns the fraction of CPU ticks
/// spent in user + system + nice states since the *previous* call — i.e. a delta,
/// not a cumulative average. First call always returns 0 (no previous data yet).
///
/// Uses wrapping subtraction on the cumulative tick counters so it handles the
/// natural_t (UInt32) overflow that occurs on machines with very long uptimes.
final class CPUSampler {

    private var prevUser:   UInt32 = 0
    private var prevSystem: UInt32 = 0
    private var prevIdle:   UInt32 = 0
    private var prevNice:   UInt32 = 0
    private var hasPrev = false

    /// Returns the active CPU fraction (0.0–1.0) since the last call.
    func sample() -> Double {
        var info  = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride /
            MemoryLayout<integer_t>.stride)

        let kern = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kern == KERN_SUCCESS else { return 0 }

        // cpu_ticks order: USER, SYSTEM, IDLE, NICE  (CPU_STATE_* constants)
        let user   = info.cpu_ticks.0
        let system = info.cpu_ticks.1
        let idle   = info.cpu_ticks.2
        let nice   = info.cpu_ticks.3

        defer {
            prevUser = user; prevSystem = system
            prevIdle = idle; prevNice   = nice
            hasPrev = true
        }
        guard hasPrev else { return 0 }

        // Wrapping subtraction handles UInt32 tick-counter overflow on long-running systems.
        let dUser   = user   &- prevUser
        let dSystem = system &- prevSystem
        let dIdle   = idle   &- prevIdle
        let dNice   = nice   &- prevNice
        let dTotal  = dUser + dSystem + dIdle + dNice
        guard dTotal > 0 else { return 0 }
        return Double(dUser + dSystem + dNice) / Double(dTotal)
    }
}
