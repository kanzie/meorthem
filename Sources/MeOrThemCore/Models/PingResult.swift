import Foundation

public struct PingResult {
    public let timestamp: Date
    /// Average RTT in milliseconds, nil if all packets lost
    public let rtt: Double?
    /// Packet loss 0–100
    public let lossPercent: Double
    /// Jitter (std-dev of RTTs), nil if fewer than 2 samples
    public let jitter: Double?

    public var isReachable: Bool { rtt != nil }

    public init(timestamp: Date, rtt: Double?, lossPercent: Double, jitter: Double?) {
        self.timestamp = timestamp
        self.rtt = rtt
        self.lossPercent = lossPercent
        self.jitter = jitter
    }
}
