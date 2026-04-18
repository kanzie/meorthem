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
    /// Per-resolver RTT points. `targetLabel` = resolver name for color-coding.
    @Published private(set) var dnsPoints:         [ChartPoint] = []
    @Published private(set) var incidents:         [SQLiteStore.IncidentRow] = []
    /// Cross-session average RTT per hour-of-day (0–23) from the last 30 days of aggregates.
    @Published private(set) var hourlyRTTAverages: [Int: Double] = [:]
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

    deinit {
        loadTask?.cancel()
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
                // For wide windows we prefer aggregated minute-level rows, but also
                // include raw samples for the recent period (data younger than the raw
                // retention window hasn't been rolled up yet and lives only in ping_samples).
                let rows: [SQLiteStore.PingRow]
                if useAgg {
                    let aggRows = db.aggregatedPingRows(for: target.id, from: from, to: now)
                    let rawRows = db.pingRows(for: target.id, from: from, to: now)
                    // Aggregates and raw rows cover disjoint time ranges in steady state
                    // (aggregateAndPrune deletes raw rows after rolling them up). During the
                    // first 7 days of operation only raw rows exist, so combining is safe.
                    rows = (aggRows + rawRows).sorted { $0.timestamp < $1.timestamp }
                } else {
                    rows = db.pingRows(for: target.id, from: from, to: now)
                }

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

            // DNS resolver samples — raw 7-day table only; no aggregates.
            // Cap at 7 days regardless of selected window.
            let dnsFrom    = max(from, now.addingTimeInterval(-7 * 86_400))
            let dnsRawRows = db.dnsResolverRows(from: dnsFrom, to: now)
            let dnsPoints: [ChartPoint] = dnsRawRows.compactMap { row in
                guard let ms = row.resolveMs else { return nil }
                return ChartPoint(timestamp: row.timestamp, value: ms,
                                  targetLabel: row.resolverName)
            }
            // Downsample per resolver to keep chart responsive
            let dnsDownsampled: [ChartPoint]
            if dnsPoints.count > maxPts {
                let stride = Double(dnsPoints.count) / Double(maxPts)
                dnsDownsampled = (0..<maxPts).map { i in
                    dnsPoints[min(Int((Double(i) * stride).rounded()), dnsPoints.count - 1)]
                }
            } else {
                dnsDownsampled = dnsPoints
            }

            guard !Task.isCancelled else { return }

            // Capture computed values as let bindings for safe transfer across isolation
            let finalLatency   = latency
            let finalLoss      = loss
            let finalJitter    = jitter
            let finalWifi      = wifiPoints
            let finalDNS       = dnsDownsampled
            let finalIncidents = recentIncidents

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rangeStart    = from
                self.rangeEnd      = now
                self.latencyPoints = finalLatency
                self.lossPoints    = finalLoss
                self.jitterPoints  = finalJitter
                self.wifiRSSI      = finalWifi
                self.dnsPoints     = finalDNS
                self.incidents     = finalIncidents
                self.isLoading     = false
            }
        }

        // Load cross-session hourly averages independently (not window-scoped; always 30 days)
        loadHourlyAverages()
    }

    /// Fetches per-hour-of-day average RTT from the last 30 days of aggregates.
    /// Runs off the main thread; result is safe to use in chart views.
    func loadHourlyAverages() {
        let db = self.db
        Task.detached(priority: .utility) { [weak self] in
            let averages = db.hourlyRTTAverages(lookback: 30 * 86_400, minSampleCount: 3)
            await MainActor.run { [weak self] in
                self?.hourlyRTTAverages = averages
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
