import Foundation

/// Records a single network quality degradation event: start time, trigger metric(s), severity, and resolution.
struct ConnectionEvent: Codable, Identifiable {
    let id: UUID
    /// MetricStatus.rawValue (1 = yellow, 2 = red) recorded at degradation onset.
    let severityRaw: Int
    let startTime: Date
    /// Human-readable description of what metric triggered the degradation,
    /// e.g. "high latency (285ms)" or "packet loss (8.2%), high jitter (45ms)".
    let cause: String
    /// nil while the event is still ongoing.
    var endTime: Date?

    init(severity: MetricStatus, startTime: Date = Date(), cause: String) {
        self.id         = UUID()
        self.severityRaw = severity.rawValue
        self.startTime  = startTime
        self.cause      = cause
        self.endTime    = nil
    }

    /// Reconstruct from persistent storage (SQLite or UserDefaults) with a known ID.
    init(id: UUID, severityRaw: Int, startTime: Date, cause: String, endTime: Date?) {
        self.id          = id
        self.severityRaw = severityRaw
        self.startTime   = startTime
        self.cause       = cause
        self.endTime     = endTime
    }

    var severity: MetricStatus { MetricStatus(rawValue: severityRaw) ?? .yellow }
    var isActive: Bool { endTime == nil }

    /// Elapsed time (if active) or total duration (if resolved), formatted as "1m 23s".
    func durationString(relativeTo now: Date = Date()) -> String {
        let end  = endTime ?? now
        let secs = max(0, Int(end.timeIntervalSince(startTime)))
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60; let s = secs % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }

    /// Short timestamp string for menu display: "HH:mm" today, "Apr 6 14:23" otherwise.
    var timestampString: String {
        let cal = Calendar.current
        let f   = DateFormatter()
        if cal.isDateInToday(startTime) {
            f.dateFormat = "HH:mm"
        } else {
            f.dateFormat = "MMM d HH:mm"
        }
        return f.string(from: startTime)
    }

    /// Menu row prefix indicating severity: orange for yellow, red for red.
    var severityDot: String {
        switch severity {
        case .yellow: return "●"   // drawn in orange by caller
        case .red:    return "●"   // drawn in red by caller
        default:      return "●"
        }
    }
}
