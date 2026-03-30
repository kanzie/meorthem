import Foundation

struct PingResult {
    let timestamp: Date
    /// Average RTT in milliseconds, nil if all packets lost
    let rtt: Double?
    /// Packet loss 0–100
    let lossPercent: Double
    /// Jitter (std-dev of RTTs), nil if fewer than 2 samples
    let jitter: Double?

    var isReachable: Bool { rtt != nil }
}
