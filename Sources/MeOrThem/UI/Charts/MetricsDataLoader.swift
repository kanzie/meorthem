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
    /// p95 latency (ms) per target label, computed from all raw rows before downsampling.
    /// nil for targets with fewer than 20 samples (not enough data for a meaningful percentile).
    @Published private(set) var latencyP95ByTarget: [String: Double] = [:]
    /// Per-resolver RTT points. `targetLabel` = resolver name for color-coding.
    @Published private(set) var dnsPoints:         [ChartPoint] = []
    @Published private(set) var speedtestPoints:     [SQLiteStore.SpeedtestRow] = []
    @Published private(set) var incidents:           [SQLiteStore.IncidentRow] = []
    @Published private(set) var systemEvents:        [SQLiteStore.SystemEventRow] = []
    /// Availability fraction [0–1] for the currently loaded time window. nil if no data.
    @Published private(set) var availabilityFraction: Double? = nil
    /// Cross-session average RTT per hour-of-day (0–23) from the last 30 days of aggregates.
    @Published private(set) var hourlyRTTAverages:   [Int: Double] = [:]
    /// Cross-session average RTT per weekday (0=Sun … 6=Sat) from the last 30 days of aggregates.
    @Published private(set) var weekdayRTTAverages:  [Int: Double] = [:]
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
            let result = available
            await MainActor.run { [weak self] in
                self?.windowsWithData = result
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
            var p95Map   = [String: Double]()

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

                // Compute p95 from the full unsampled dataset — requires ≥20 samples.
                let rtts = rows.compactMap(\.rttMs)
                if rtts.count >= 20 {
                    let sorted = rtts.sorted()
                    let idx    = Int((Double(sorted.count - 1) * 0.95).rounded())
                    p95Map[target.label] = sorted[idx]
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

            let speedtestRows   = db.speedtestRows(from: from, to: now)
            let sysEventRows    = db.systemEventRows(from: from, to: now)
            let availFraction   = db.availabilityFraction(from: from, to: now)

            guard !Task.isCancelled else { return }

            // Capture computed values as let bindings for safe transfer across isolation
            let finalLatency      = latency
            let finalLoss         = loss
            let finalJitter       = jitter
            let finalWifi         = wifiPoints
            let finalDNS          = dnsDownsampled
            let finalSpeedtest    = speedtestRows
            let finalIncidents    = recentIncidents
            let finalSysEvents    = sysEventRows
            let finalAvailability = availFraction
            let finalP95          = p95Map

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rangeStart          = from
                self.rangeEnd            = now
                self.latencyPoints       = finalLatency
                self.lossPoints          = finalLoss
                self.jitterPoints        = finalJitter
                self.wifiRSSI            = finalWifi
                self.dnsPoints           = finalDNS
                self.speedtestPoints     = finalSpeedtest
                self.incidents           = finalIncidents
                self.systemEvents        = finalSysEvents
                self.availabilityFraction = finalAvailability
                self.latencyP95ByTarget  = finalP95
                self.isLoading           = false
            }
        }

        // Load cross-session pattern averages independently (not window-scoped; always 30 days)
        loadPatternAverages()
    }

    /// Fetches per-hour-of-day and per-weekday average RTT from the last 30 days of aggregates.
    /// Runs off the main thread; result is safe to use in chart views.
    func loadPatternAverages() {
        let db = self.db
        Task.detached(priority: .utility) { [weak self] in
            let hourly  = db.hourlyRTTAverages(lookback: 30 * 86_400, minSampleCount: 3)
            let weekday = db.weekdayRTTAverages(lookback: 30 * 86_400, minSampleCount: 5)
            await MainActor.run { [weak self] in
                self?.hourlyRTTAverages  = hourly
                self?.weekdayRTTAverages = weekday
            }
        }
    }

    /// Loads data for an explicit date range (e.g. a specific network session).
    /// Uses aggregated rows when the range exceeds 6 hours.
    func load(from: Date, to: Date) {
        loadTask?.cancel()
        isLoading = true

        let db        = self.db
        let targets   = self.targets
        let maxPts    = Self.maxPoints
        let duration  = to.timeIntervalSince(from)
        let useAgg    = duration > 6 * 3600

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }

            var latency = [ChartPoint]()
            var loss    = [ChartPoint]()
            var jitter  = [ChartPoint]()

            var p95Map = [String: Double]()

            for target in targets {
                let rows: [SQLiteStore.PingRow]
                if useAgg {
                    let aggRows = db.aggregatedPingRows(for: target.id, from: from, to: to)
                    let rawRows = db.pingRows(for: target.id, from: from, to: to)
                    rows = (aggRows + rawRows).sorted { $0.timestamp < $1.timestamp }
                } else {
                    rows = db.pingRows(for: target.id, from: from, to: to)
                }

                let rtts = rows.compactMap(\.rttMs)
                if rtts.count >= 20 {
                    let sorted = rtts.sorted()
                    let idx    = Int((Double(sorted.count - 1) * 0.95).rounded())
                    p95Map[target.label] = sorted[idx]
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

            let wifiRows    = db.wifiRows(from: from, to: to)
            let sampledWifi = Self.downsampleWifi(wifiRows, maxPoints: maxPts)
            let wifiPoints  = sampledWifi.map { w in
                ChartPoint(timestamp: w.timestamp, value: Double(w.rssi), targetLabel: "WiFi")
            }

            let recentIncidents = db.recentIncidents(limit: 200).filter {
                $0.startedAt >= from && $0.startedAt <= to
            }

            let dnsFrom    = max(from, to.addingTimeInterval(-7 * 86_400))
            let dnsRawRows = db.dnsResolverRows(from: dnsFrom, to: to)
            let dnsPoints: [ChartPoint] = dnsRawRows.compactMap { row in
                guard let ms = row.resolveMs else { return nil }
                return ChartPoint(timestamp: row.timestamp, value: ms, targetLabel: row.resolverName)
            }
            let dnsDownsampled: [ChartPoint] = dnsPoints.count > maxPts
                ? (0..<maxPts).map { i in
                    dnsPoints[min(Int((Double(i) * Double(dnsPoints.count) / Double(maxPts)).rounded()), dnsPoints.count - 1)]
                  }
                : dnsPoints

            let speedtestRows = db.speedtestRows(from: from, to: to)
            let sysEventRows  = db.systemEventRows(from: from, to: to)
            let availFraction = db.availabilityFraction(from: from, to: to)

            guard !Task.isCancelled else { return }

            let finalLatency      = latency
            let finalLoss         = loss
            let finalJitter       = jitter
            let finalWifi         = wifiPoints
            let finalDNS          = dnsDownsampled
            let finalSpeedtest    = speedtestRows
            let finalIncidents    = recentIncidents
            let finalSysEvents    = sysEventRows
            let finalAvailability = availFraction
            let finalP95          = p95Map

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.rangeStart           = from
                self.rangeEnd             = to
                self.latencyPoints        = finalLatency
                self.lossPoints           = finalLoss
                self.jitterPoints         = finalJitter
                self.wifiRSSI             = finalWifi
                self.dnsPoints            = finalDNS
                self.speedtestPoints      = finalSpeedtest
                self.incidents            = finalIncidents
                self.systemEvents         = finalSysEvents
                self.availabilityFraction = finalAvailability
                self.latencyP95ByTarget   = finalP95
                self.isLoading            = false
            }
        }

        loadPatternAverages()
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
