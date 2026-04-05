import Foundation

enum JitterCalculator {
    /// Population std-dev of RTT samples (classic jitter measure).
    /// Single-pass variance computation — avoids the intermediate array from .map{}.reduce().
    static func jitter(from rtts: [Double]) -> Double? {
        guard rtts.count > 1 else { return nil }
        let n = Double(rtts.count)
        let mean = rtts.reduce(0.0, +) / n
        let variance = rtts.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n
        return sqrt(variance)
    }
}
