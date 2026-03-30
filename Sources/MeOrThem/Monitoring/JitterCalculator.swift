import Foundation

enum JitterCalculator {
    /// Population std-dev of RTT samples (classic jitter measure).
    static func jitter(from rtts: [Double]) -> Double? {
        guard rtts.count > 1 else { return nil }
        let mean = rtts.reduce(0, +) / Double(rtts.count)
        let variance = rtts.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rtts.count)
        return sqrt(variance)
    }
}
