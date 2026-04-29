/// A composite 0–100 stability score for a network session.
///
/// Components (weights):
///   • Availability  40 pts — fraction of session time without an active incident
///   • Latency       25 pts — mean RTT normalised to known quality thresholds
///   • Loss          25 pts — mean packet-loss percentage
///   • Jitter        10 pts — mean jitter normalised to quality thresholds
///
/// A nil component means insufficient samples for that metric.
public struct ConnectionStabilityScore: Sendable {

    // MARK: - Component scores (0 to component max each)

    /// 0–40 pts.  nil if no incidents table data is available.
    public let availabilityPts: Double?
    /// 0–25 pts.  nil if fewer than 5 ping samples.
    public let latencyPts:      Double?
    /// 0–25 pts.  nil if fewer than 5 ping samples.
    public let lossPts:         Double?
    /// 0–10 pts.  nil if no jitter data.
    public let jitterPts:       Double?

    // MARK: - Derived

    /// 0–100 composite score.  Only components with data contribute;
    /// the weight of missing components is redistributed proportionally.
    public var total: Double {
        var score  = 0.0
        var weight = 0.0
        func add(_ pts: Double?, _ w: Double) {
            guard let p = pts else { return }
            score  += p
            weight += w
        }
        add(availabilityPts, 40)
        add(latencyPts,      25)
        add(lossPts,         25)
        add(jitterPts,       10)
        guard weight > 0 else { return 0 }
        // Rescale to 100 when some components are missing
        return (score / weight) * 100
    }

    /// Letter grade derived from `total`.
    public var grade: String {
        switch total {
        case 90...: return "A"
        case 75...: return "B"
        case 60...: return "C"
        case 40...: return "D"
        default:    return "F"
        }
    }

    /// Short accessibility label.
    public var label: String { "\(Int(total.rounded()))/100 (\(grade))" }

    // MARK: - Factory

    /// Computes the score from raw session metrics.
    ///
    /// - Parameters:
    ///   - availability:   0–1 fraction of incident-free time, or nil if unknown.
    ///   - meanRTTMs:      Mean round-trip time in milliseconds, or nil if < 5 samples.
    ///   - meanLossPct:    Mean packet-loss percentage (0–100), or nil if < 5 samples.
    ///   - meanJitterMs:   Mean jitter in milliseconds, or nil if no jitter data.
    public static func compute(
        availability: Double?,
        meanRTTMs:    Double?,
        meanLossPct:  Double?,
        meanJitterMs: Double?
    ) -> ConnectionStabilityScore {

        let avail: Double? = availability.map { min($0, 1.0) * 40 }

        let lat: Double? = meanRTTMs.map { rtt in
            switch rtt {
            case ..<20:  return 25
            case ..<50:  return 21
            case ..<100: return 17
            case ..<150: return 12
            case ..<200: return  7
            default:     return  0
            }
        }

        let loss: Double? = meanLossPct.map { l in
            switch l {
            case ..<0.1:  return 25
            case ..<0.5:  return 21
            case ..<1.0:  return 16
            case ..<2.0:  return 10
            case ..<5.0:  return  5
            default:      return  0
            }
        }

        let jit: Double? = meanJitterMs.map { j in
            switch j {
            case ..<5:   return 10
            case ..<15:  return  8
            case ..<30:  return  6
            case ..<50:  return  3
            default:     return  0
            }
        }

        return ConnectionStabilityScore(
            availabilityPts: avail,
            latencyPts:      lat,
            lossPts:         loss,
            jitterPts:       jit
        )
    }
}
