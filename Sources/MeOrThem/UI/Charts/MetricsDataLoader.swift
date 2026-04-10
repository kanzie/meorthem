import Foundation
@preconcurrency import MeOrThemCore

// MARK: - TimeWindow

enum TimeWindow: String, CaseIterable, Identifiable {
    case hour1  = "1h"
    case hour6  = "6h"
    case hour24 = "24h"
    case day7   = "7d"
    case day30  = "30d"
    case day90  = "90d"
    case year1  = "1y"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour1:  return "1 Hour"
        case .hour6:  return "6 Hours"
        case .hour24: return "24 Hours"
        case .day7:   return "7 Days"
        case .day30:  return "30 Days"
        case .day90:  return "90 Days"
        case .year1:  return "1 Year"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .hour1:  return 3600
        case .hour6:  return 6 * 3600
        case .hour24: return 24 * 3600
        case .day7:   return 7 * 86400
        case .day30:  return 30 * 86400
        case .day90:  return 90 * 86400
        case .year1:  return 366 * 86400
        }
    }

    /// Use aggregated (per-minute) rows when the window is wider than 6 hours.
    var useAggregates: Bool { duration > 6 * 3600 }
}

// MARK: - ChartPoint

struct ChartPoint: Identifiable {
    let id          = UUID()
    let timestamp:   Date
    let value:       Double
    let targetLabel: String
}

// MARK: - MetricsDataLoader

@MainActor
final class MetricsDataLoader: ObservableObject {
    @Published private(set) var latencyPoints:   [ChartPoint] = []
    @Published private(set) var lossPoints:      [ChartPoint] = []
    @Published private(set) var jitterPoints:    [ChartPoint] = []
    @Published private(set) var wifiRSSI:        [ChartPoint] = []
    @Published private(set) var incidents:       [SQLiteStore.IncidentRow] = []
    @Published private(set) var isLoading        = false
    @Published private(set) var rangeStart       = Date()
    @Published private(set) var rangeEnd         = Date()
    /// Windows that have at least one data point; defaults to all so the picker looks
    /// enabled on first render and disables only after the async check finishes.
    @Published private(set) var windowsWithData: Set<TimeWindow> = Set(TimeWindow.allCases)

    let targets: [PingTarget]
    private let db: SQLiteStore
    private static let maxPoints = 600
    private var loadTask: Task<Void, Never>?

    init(db: SQLiteStore, targets: [PingTarget]) {
        self.db      = db
        self.targets = targets
    }

    /// Probes every time window with a LIMIT-1 query and updates windowsWithData.
    /// Pass specific target IDs to check only those targets (e.g. when a single target
    /// is selected in the picker); pass nil to check across all targets.
    /// Runs off the main thread so it doesn't block the UI.
    func checkAvailableWindows(for targetIDs: [UUID]? = nil) {
        let db  = self.db
        let ids = targetIDs
        Task.detached(priority: .utility) { [weak self] in
            let now = Date()
            var available = Set<TimeWindow>()
            for window in TimeWindow.allCases {
                let from = now.addingTimeInterval(-window.duration)
                let hasData: Bool
                if let ids, !ids.isEmpty {
                    hasData = db.hasPingData(forTargetIDs: ids, from: from, to: now)
                } else {
                    hasData = db.hasPingData(from: from, to: now)
                }
                if hasData { available.insert(window) }
            }
            await MainActor.run { [weak self] in
                self?.windowsWithData = available
            }
        }
    }

    func load(window: TimeWindow) {
        loadTask?.cancel()
        isLoading = true

        let now  = Date()
        let from = now.addingTimeInterval(-window.duration)

        let db        = self.db
        let targets   = self.targets
        let maxPts    = Self.maxPoints
        let useAgg    = window.useAggregates

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }

            var latency  = [ChartPoint]()
            var loss     = [ChartPoint]()
            var jitter   = [ChartPoint]()

            for target in targets {
                let rows = useAgg
                    ? db.aggregatedPingRows(for: target.id, from: from, to: now)
                    : db.pingRows(for: target.id, from: from, to: now)

                let sampled = Self.downsample(rows, maxPoints: maxPts / max(targets.count, 1))
                for r in sampled {
                    if let rtt = r.rttMs {
                        latency.append(ChartPoint(timestamp: r.timestamp, value: rtt, targetLabel: target.label))
                    }
                    loss.append(ChartPoint(timestamp: r.timestamp, value: r.lossPct, targetLabel: target.label))
                    if let j = r.jitterMs {
                        jitter.append(ChartPoint(timestamp: r.timestamp, value: j, targetLabel: target.label))
                    }
                }
            }

            let wifiRows  = db.wifiRows(from: from, to: now)
            let sampledWifi = Self.downsampleWifi(wifiRows, maxPoints: maxPts)
            let wifiPoints  = sampledWifi.map { w in
                ChartPoint(timestamp: w.timestamp, value: Double(w.rssi), targetLabel: "WiFi")
            }

            let recentIncidents = db.recentIncidents(limit: 200).filter {
                $0.startedAt >= from && $0.startedAt <= now
            }

            guard !Task.isCancelled else { return }

            // Capture computed values as let bindings for safe transfer across isolation
            let finalLatency   = latency
            let finalLoss      = loss
            let finalJitter    = jitter
            let finalWifi      = wifiPoints
            let finalIncidents = recentIncidents

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rangeStart    = from
                self.rangeEnd      = now
                self.latencyPoints = finalLatency
                self.lossPoints    = finalLoss
                self.jitterPoints  = finalJitter
                self.wifiRSSI      = finalWifi
                self.incidents     = finalIncidents
                self.isLoading     = false
            }
        }
    }

    // MARK: - Downsampling (stride-based)

    nonisolated private static func downsample(_ rows: [SQLiteStore.PingRow], maxPoints: Int) -> [SQLiteStore.PingRow] {
        guard rows.count > maxPoints, maxPoints > 0 else { return rows }
        let stride = Double(rows.count) / Double(maxPoints)
        return (0..<maxPoints).map { i in rows[min(Int((Double(i) * stride).rounded()), rows.count - 1)] }
    }

    nonisolated private static func downsampleWifi(_ rows: [SQLiteStore.WiFiRow], maxPoints: Int) -> [SQLiteStore.WiFiRow] {
        guard rows.count > maxPoints, maxPoints > 0 else { return rows }
        let stride = Double(rows.count) / Double(maxPoints)
        return (0..<maxPoints).map { i in rows[min(Int((Double(i) * stride).rounded()), rows.count - 1)] }
    }
}
