import AppKit

enum MetricStatus: Int, Comparable, CaseIterable {
    case green  = 0
    case yellow = 1
    case red    = 2

    static func < (lhs: MetricStatus, rhs: MetricStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var color: NSColor {
        switch self {
        case .green:  return .systemGreen
        case .yellow: return .systemYellow
        case .red:    return .systemRed
        }
    }

    var label: String {
        switch self {
        case .green:  return "Good"
        case .yellow: return "Degraded"
        case .red:    return "Poor"
        }
    }
}

extension MetricStatus {
    static func forPingResult(_ result: PingResult?, thresholds: Thresholds) -> MetricStatus {
        guard let r = result else { return .red }
        if r.lossPercent >= thresholds.lossRedPct   { return .red }
        if r.lossPercent >= thresholds.lossYellowPct { return .yellow }
        if let rtt = r.rtt {
            if rtt >= thresholds.latencyRedMs    { return .red }
            if rtt >= thresholds.latencyYellowMs { return .yellow }
        }
        if let j = r.jitter {
            if j >= thresholds.jitterRedMs    { return .red }
            if j >= thresholds.jitterYellowMs { return .yellow }
        }
        return .green
    }

    static func forRSSI(_ rssi: Int) -> MetricStatus {
        if rssi < -80 { return .red }
        if rssi < -67 { return .yellow }
        return .green
    }
}

struct Thresholds: Codable {
    // Tuned for video conferencing: values where call quality starts to degrade
    var latencyYellowMs: Double = 100   // noticeable lag on calls
    var latencyRedMs:    Double = 200   // severe call degradation
    var lossYellowPct:   Double = 1     // video artifacts begin
    var lossRedPct:      Double = 3     // calls frequently drop/freeze
    var jitterYellowMs:  Double = 30    // audio glitches begin
    var jitterRedMs:     Double = 80    // severe audio/video disruption

    static let `default` = Thresholds()
}
