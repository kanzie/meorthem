import AppKit
import MeOrThemCore

extension MetricStatus {
    var color: NSColor {
        switch self {
        case .green:  return .systemGreen
        case .yellow: return .systemYellow
        case .red:    return .systemRed
        }
    }
}
