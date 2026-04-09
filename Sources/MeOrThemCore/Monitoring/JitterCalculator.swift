import Foundation

enum JitterCalculator {
    /// Population std-dev of RTT samples (classic jitter measure).
    /// Single-pass variance computation — avoids the intermediate array from .map{}.reduce().
    static func jitter(from rtts: [Double]) -> Double? {
        let finite = rtts.filter { $0.isFinite }
        guard finite.count > 1 else { return nil }
        let n = Double(finite.count)
        let mean = finite.reduce(0.0, +) / n
        let variance = finite.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let result = sqrt(variance)
        return result.isFinite ? result : nil
    }
}
