import SwiftUI
import Charts
import MeOrThemCore

// MARK: - Target color palette

private let targetColorPalette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo]

private func targetColor(index: Int) -> Color {
    targetColorPalette[index % targetColorPalette.count]
}

// MARK: - HoverTooltip

private struct HoverTooltip: View {
    let date: Date
    let entries: [(label: String, value: Double, color: Color)]
    let unit: String

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Self.fmt.string(from: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(entries, id: \.label) { entry in
                HStack(spacing: 6) {
                    Circle()
                        .fill(entry.color)
                        .frame(width: 8, height: 8)
                    Text(entry.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f \(unit)", entry.value))
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
    }
}

// MARK: - MetricsChartsView

struct MetricsChartsView: View {
    @StateObject private var loader: MetricsDataLoader
    @State private var selectedWindow: TimeWindow = .hour1
    @State private var selectedTargetIndex: Int = 0
    /// Stores the exact timestamp of the nearest snapped data point.
    /// Only changes when the cursor crosses into a new point's territory,
    /// so the chart bodies (which have no dependency on this) never re-render on hover.
    @State private var hoveredDate: Date? = nil
    /// Throttles hover computation to ≤60 FPS across all charts.
    @State private var lastHoverCompute: Date = .distantPast
    /// Hovered hour label for the daily-pattern bar chart (String categorical axis).
    @State private var hoveredHourLabel: String? = nil

    private let thresholds: Thresholds
    private let bandwidthRedMbps:    Double
    private let bandwidthYellowMbps: Double

    init(db: SQLiteStore, targets: [PingTarget], thresholds: Thresholds,
         bandwidthRedMbps: Double = 10, bandwidthYellowMbps: Double = 25) {
        _loader     = StateObject(wrappedValue: MetricsDataLoader(db: db, targets: targets))
        self.thresholds          = thresholds
        self.bandwidthRedMbps    = bandwidthRedMbps
        self.bandwidthYellowMbps = bandwidthYellowMbps
    }

    // MARK: - Derived target data

    private var visibleTargets: [PingTarget] {
        if selectedTargetIndex == 0 { return loader.targets }
        let idx = selectedTargetIndex - 1
        guard loader.targets.indices.contains(idx) else { return loader.targets }
        return [loader.targets[idx]]
    }

    private var visibleTargetLabels: [String] { visibleTargets.map(\.label) }

    private var visibleTargetColors: [Color] {
        if selectedTargetIndex == 0 {
            return loader.targets.indices.map { targetColor(index: $0) }
        }
        return [targetColor(index: selectedTargetIndex - 1)]
    }

    private var colorMap: [String: Color] {
        Dictionary(uniqueKeysWithValues: zip(visibleTargetLabels, visibleTargetColors))
    }

    private var dnsColorMap: [String: Color] {
        Dictionary(uniqueKeysWithValues: dnsResolverNames.map { ($0, dnsColor(for: $0)) })
    }

    private var filteredLatency: [ChartPoint] {
        let labels = Set(visibleTargetLabels)
        return loader.latencyPoints.filter { labels.contains($0.targetLabel) }
    }
    private var filteredLoss: [ChartPoint] {
        let labels = Set(visibleTargetLabels)
        return loader.lossPoints.filter { labels.contains($0.targetLabel) }
    }
    private var filteredJitter: [ChartPoint] {
        let labels = Set(visibleTargetLabels)
        return loader.jitterPoints.filter { labels.contains($0.targetLabel) }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if loader.isLoading {
                    loadingView
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            latencyCard
                            lossCard
                            jitterCard
                            if !loader.wifiRSSI.isEmpty { wifiCard }
                            if !loader.dnsPoints.isEmpty { dnsCard }
                            speedtestCard
                            if loader.hourlyRTTAverages.count >= 4 { hourlyPatternCard }
                            if !loader.incidents.isEmpty { incidentList }
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                Button("Close") {
                    NSApplication.shared.keyWindow?.performClose(nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 780, minHeight: 500)
        .toolbar {
            if loader.targets.count > 1 {
                ToolbarItem(placement: .navigation) {
                    targetPicker
                }
            }
            ToolbarItem(placement: .principal) {
                windowPicker
            }
            ToolbarItem(placement: .primaryAction) {
                Button { loader.load(window: selectedWindow) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
        .onAppear {
            loader.load(window: selectedWindow)
            loader.checkAvailableWindows(for: visibleTargets.map(\.id))
        }
        .onChange(of: selectedWindow) { _, w in loader.load(window: w) }
        .onChange(of: selectedTargetIndex) { _, _ in
            // Re-check which windows have data for the newly selected target.
            loader.checkAvailableWindows(for: visibleTargets.map(\.id))
        }
    }

    // MARK: - Toolbar items

    private var targetPicker: some View {
        Menu {
            Button("All Targets") { selectedTargetIndex = 0 }
            Divider()
            ForEach(loader.targets.indices, id: \.self) { i in
                Button(loader.targets[i].label) { selectedTargetIndex = i + 1 }
            }
        } label: {
            Label(
                selectedTargetIndex == 0 ? "All Targets" : loader.targets[selectedTargetIndex - 1].label,
                systemImage: "target"
            )
        }
        .fixedSize()
    }

    /// Custom segmented-style picker that can disable individual time windows.
    /// SwiftUI's .pickerStyle(.segmented) has no per-item disabled state.
    private var windowPicker: some View {
        HStack(spacing: 0) {
            ForEach(TimeWindow.allCases) { w in
                let isSelected = selectedWindow == w
                let hasData   = loader.windowsWithData.contains(w)
                Button { selectedWindow = w } label: {
                    Text(w.label)
                        .font(.caption)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            isSelected
                                ? RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlColor))
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)
                                : nil
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    hasData
                        ? (isSelected ? Color.primary : Color.secondary)
                        : Color.secondary.opacity(0.3)
                )
                .disabled(!hasData)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
    }

    // MARK: - Loading / Empty

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading data…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func emptyView(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    // MARK: - Hover helpers

    /// Finds the nearest data point per target using binary search.
    /// Points within each target group are sorted by timestamp (guaranteed by DB ORDER BY).
    private func nearestPoints(to date: Date, in points: [ChartPoint]) -> [ChartPoint] {
        // Group once per hover event — O(n), but n ≤ maxPoints and fires at most 60/sec.
        let byTarget = Dictionary(grouping: points, by: \.targetLabel)
        return byTarget.compactMap { _, pts -> ChartPoint? in
            guard !pts.isEmpty else { return nil }
            // Binary search for insertion point (pts sorted by timestamp from DB)
            var lo = 0, hi = pts.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if pts[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return pts[0] }
            let prev = pts[lo - 1], curr = pts[lo]
            return abs(prev.timestamp.timeIntervalSince(date)) <= abs(curr.timestamp.timeIntervalSince(date))
                ? prev : curr
        }
        .sorted { $0.targetLabel < $1.targetLabel }
    }

    /// Returns the nearest point per target to hoveredDate.
    /// Uses nearest-match (not exact timestamp) because concurrent pings for different
    /// targets complete at slightly different times within the same poll tick.
    private func snappedPoints(in points: [ChartPoint]) -> [ChartPoint] {
        guard let date = hoveredDate else { return [] }
        let byTarget = Dictionary(grouping: points, by: \.targetLabel)
        return byTarget.compactMap { _, pts -> ChartPoint? in
            pts.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) })
        }
        .sorted { $0.targetLabel < $1.targetLabel }
    }

    private func tooltipEntries(snapped: [ChartPoint],
                                using cm: [String: Color]) -> [(label: String, value: Double, color: Color)] {
        snapped.compactMap { p in
            guard let color = cm[p.targetLabel] else { return nil }
            return (p.targetLabel, p.value, color)
        }
    }

    // MARK: - Legend

    private func legend(labels: [String], colors: [Color]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(zip(labels, colors)), id: \.0) { label, color in
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Hover overlay
    //
    // Performance design:
    //   • Chart bodies have NO dependency on hoveredDate — they never re-render on hover.
    //   • hoveredDate snaps to exact data-point timestamps, so state only changes when
    //     the cursor crosses into a new point's territory (not on every pixel move).
    //   • Markers and tooltip are drawn here, in the lightweight overlay layer only.

    @ViewBuilder
    private func hoverOverlay(
        proxy: ChartProxy,
        geometry: GeometryProxy,
        points: [ChartPoint],
        unit: String,
        overrideColorMap: [String: Color]? = nil
    ) -> some View {
        let cm     = overrideColorMap ?? colorMap
        let origin = proxy.plotFrame.map { geometry[$0].origin } ?? .zero

        // Transparent hit-test surface for hover detection
        Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    // Throttle to ≤60 FPS — display link fires at 120 Hz on ProMotion displays.
                    let now = Date()
                    guard now.timeIntervalSince(lastHoverCompute) >= 1.0 / 60.0 else { break }
                    lastHoverCompute = now
                    guard let rawDate: Date = proxy.value(atX: loc.x - origin.x) else { break }
                    // Snap to the nearest actual data timestamp; only trigger a state
                    // update when the snapped point changes (not every cursor pixel).
                    let snapped = nearestPoints(to: rawDate, in: points).first?.timestamp
                    if snapped != hoveredDate { hoveredDate = snapped }
                case .ended:
                    hoveredDate = nil
                }
            }

        if let date = hoveredDate {
            let snapped = snappedPoints(in: points)

            if let first = snapped.first, let xPos = proxy.position(forX: first.timestamp) {
                let xInView = xPos + origin.x

                // Vertical cursor line
                Path { p in
                    p.move(to: CGPoint(x: xInView, y: 0))
                    p.addLine(to: CGPoint(x: xInView, y: geometry.size.height))
                }
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)

                // Per-target snap markers
                ForEach(snapped) { p in
                    if let px = proxy.position(forX: p.timestamp),
                       let py = proxy.position(forY: p.value) {
                        Circle()
                            .fill(cm[p.targetLabel] ?? .primary)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                            .shadow(color: .black.opacity(0.15), radius: 2)
                            .position(x: px + origin.x, y: py + origin.y)
                    }
                }

                // Tooltip card — reuse already-computed snapped to avoid a second O(n) scan
                let entries = tooltipEntries(snapped: snapped, using: cm)
                if !entries.isEmpty {
                    HoverTooltip(date: date, entries: entries, unit: unit)
                        .fixedSize()
                        .position(
                            x: xInView < geometry.size.width / 2
                                ? min(xInView + 100, geometry.size.width - 80)
                                : max(xInView - 100, 80),
                            y: origin.y + 28
                        )
                }
            }
        }
    }

    // MARK: - Latency Card

    private var latencyCard: some View {
        ChartCard(title: "Latency", subtitle: "Round-trip time in milliseconds") {
            if filteredLatency.isEmpty {
                emptyView(icon: "waveform.path.ecg", message: "No latency data for this period")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Chart {
                        // Threshold reference lines (dashed, subtle)
                        RuleMark(y: .value("Yellow", thresholds.latencyYellowMs))
                            .foregroundStyle(Color.orange.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("Red", thresholds.latencyRedMs))
                            .foregroundStyle(Color.red.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        // Cap at 10 markers — more than that creates visual noise.
                        // The full incident list is always shown in the Incidents card below.
                        ForEach(loader.incidents.prefix(10)) { inc in
                            RuleMark(x: .value("Incident", inc.startedAt))
                                .foregroundStyle(incidentColor(inc).opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        }

                        // Area fills + lines per target
                        ForEach(filteredLatency) { p in
                            AreaMark(
                                x: .value("Time", p.timestamp),
                                yStart: .value("Zero", 0),
                                yEnd:   .value("RTT ms", p.value)
                            )
                            .foregroundStyle(by: .value("Target", p.targetLabel))
                            .opacity(0.18)
                            .interpolationMethod(.catmullRom)

                            LineMark(x: .value("Time", p.timestamp), y: .value("RTT ms", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                .interpolationMethod(.catmullRom)
                        }

                        // Regression trend line (only shown when a meaningful slope exists)
                        if let trend = latencyTrendLine {
                            let trendColor = trend.end.1 > trend.start.1 ? Color.red : Color.green
                            LineMark(
                                x: .value("Time", trend.start.0),
                                y: .value("RTT ms", trend.start.1),
                                series: .value("Series", "Trend")
                            )
                            .foregroundStyle(trendColor.opacity(0.70))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))

                            LineMark(
                                x: .value("Time", trend.end.0),
                                y: .value("RTT ms", trend.end.1),
                                series: .value("Series", "Trend")
                            )
                            .foregroundStyle(trendColor.opacity(0.70))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        }
                    }
                    .chartForegroundStyleScale(domain: visibleTargetLabels, range: visibleTargetColors)
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        }
                    }
                    .chartYScale(domain: 0...maxLatencyY)
                    .frame(height: 200)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            hoverOverlay(proxy: proxy, geometry: geo,
                                         points: filteredLatency, unit: "ms")
                        }
                    }

                    if visibleTargetLabels.count > 1 {
                        legend(labels: visibleTargetLabels, colors: visibleTargetColors)
                    }
                }
            }
        }
    }

    private var maxLatencyY: Double {
        let peak = filteredLatency.map(\.value).max() ?? 0
        return max(peak * 1.2, thresholds.latencyRedMs * 1.5)
    }

    /// Two-point regression line for the latency chart. Returns (start, end) Date→ms pairs,
    /// or nil when the trend is too weak or there's insufficient data.
    private var latencyTrendLine: (start: (Date, Double), end: (Date, Double))? {
        let pts = filteredLatency
        guard pts.count >= 20 else { return nil }
        let origin = loader.rangeStart
        let pairs  = pts.map { ($0.timestamp.timeIntervalSince(origin), $0.value) }
        let n  = Double(pairs.count)
        let sX = pairs.reduce(0) { $0 + $1.0 }
        let sY = pairs.reduce(0) { $0 + $1.1 }
        let sXY = pairs.reduce(0) { $0 + $1.0 * $1.1 }
        let sX2 = pairs.reduce(0) { $0 + $1.0 * $1.0 }
        let denom = n * sX2 - sX * sX
        guard abs(denom) > 0 else { return nil }
        let slope     = (n * sXY - sX * sY) / denom
        let intercept = (sY - slope * sX) / n
        // Only show when slope > 0.3 ms/min (upward) or < -0.3 ms/min (downward)
        guard abs(slope * 60) > 0.3 else { return nil }
        let endX = loader.rangeEnd.timeIntervalSince(origin)
        let startY = max(0, intercept)
        let endY   = max(0, intercept + slope * endX)
        return ((loader.rangeStart, startY), (loader.rangeEnd, endY))
    }

    // MARK: - Loss Card

    private var lossCard: some View {
        ChartCard(title: "Packet Loss", subtitle: "Percentage of pings lost") {
            if filteredLoss.isEmpty {
                emptyView(icon: "exclamationmark.triangle", message: "No loss data for this period")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Chart {
                        RuleMark(y: .value("Yellow", thresholds.lossYellowPct))
                            .foregroundStyle(Color.orange.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("Red", thresholds.lossRedPct))
                            .foregroundStyle(Color.red.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        // Cap at 10 markers — more than that creates visual noise.
                        // The full incident list is always shown in the Incidents card below.
                        ForEach(loader.incidents.prefix(10)) { inc in
                            RuleMark(x: .value("Incident", inc.startedAt))
                                .foregroundStyle(incidentColor(inc).opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        }

                        ForEach(filteredLoss) { p in
                            AreaMark(x: .value("Time", p.timestamp),
                                     yStart: .value("Zero", 0),
                                     yEnd:   .value("Loss %", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                                .opacity(0.18)
                            LineMark(x: .value("Time", p.timestamp),
                                     y: .value("Loss %", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    .chartForegroundStyleScale(domain: visibleTargetLabels, range: visibleTargetColors)
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        }
                    }
                    .chartYScale(domain: 0...maxLossY)
                    .frame(height: 160)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            hoverOverlay(proxy: proxy, geometry: geo,
                                         points: filteredLoss, unit: "%")
                        }
                    }

                    if visibleTargetLabels.count > 1 {
                        legend(labels: visibleTargetLabels, colors: visibleTargetColors)
                    }
                }
            }
        }
    }

    private var maxLossY: Double {
        let peak = filteredLoss.map(\.value).max() ?? 0
        return max(peak * 1.2, thresholds.lossRedPct * 2)
    }

    // MARK: - Jitter Card

    private var jitterCard: some View {
        ChartCard(title: "Jitter", subtitle: "Variation in round-trip time") {
            if filteredJitter.isEmpty {
                emptyView(icon: "waveform", message: "No jitter data for this period")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Chart {
                        RuleMark(y: .value("Yellow", thresholds.jitterYellowMs))
                            .foregroundStyle(Color.orange.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("Red", thresholds.jitterRedMs))
                            .foregroundStyle(Color.red.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        // Cap at 10 markers — more than that creates visual noise.
                        // The full incident list is always shown in the Incidents card below.
                        ForEach(loader.incidents.prefix(10)) { inc in
                            RuleMark(x: .value("Incident", inc.startedAt))
                                .foregroundStyle(incidentColor(inc).opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        }

                        ForEach(filteredJitter) { p in
                            AreaMark(x: .value("Time", p.timestamp),
                                     yStart: .value("Zero", 0),
                                     yEnd:   .value("Jitter ms", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                                .opacity(0.18)
                            LineMark(x: .value("Time", p.timestamp),
                                     y: .value("Jitter ms", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                    .chartForegroundStyleScale(domain: visibleTargetLabels, range: visibleTargetColors)
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        }
                    }
                    .chartYScale(domain: 0...maxJitterY)
                    .frame(height: 160)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            hoverOverlay(proxy: proxy, geometry: geo,
                                         points: filteredJitter, unit: "ms")
                        }
                    }

                    if visibleTargetLabels.count > 1 {
                        legend(labels: visibleTargetLabels, colors: visibleTargetColors)
                    }
                }
            }
        }
    }

    private var maxJitterY: Double {
        let peak = filteredJitter.map(\.value).max() ?? 0
        return max(peak * 1.2, thresholds.jitterRedMs * 1.5)
    }

    // MARK: - WiFi Card

    private var wifiCard: some View {
        ChartCard(title: "WiFi Signal", subtitle: "RSSI in dBm — higher (less negative) is better") {
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    RuleMark(y: .value("Good", -67))
                        .foregroundStyle(Color.green.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    RuleMark(y: .value("Poor", -80))
                        .foregroundStyle(Color.orange.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    ForEach(loader.wifiRSSI) { p in
                        AreaMark(x: .value("Time", p.timestamp),
                                 yStart: .value("Base", -100),
                                 yEnd:   .value("RSSI", p.value))
                            .foregroundStyle(Color.cyan.opacity(0.20))
                        LineMark(x: .value("Time", p.timestamp),
                                 y: .value("RSSI", p.value))
                            .foregroundStyle(Color.cyan)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    }
                }
                .chartYScale(domain: -100...0)
                .frame(height: 160)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        hoverOverlay(proxy: proxy, geometry: geo,
                                     points: loader.wifiRSSI, unit: "dBm")
                    }
                }
            }
        }
    }

    // MARK: - DNS card

    /// Fixed resolver color palette — keyed by name fragment so colors are stable
    /// as resolvers are enabled/disabled.
    private func dnsColor(for resolverName: String) -> Color {
        let name = resolverName.lowercased()
        if name.contains("cloudflare") { return .orange }
        if name.contains("google")     { return .blue }
        if name.contains("quad9")      { return .purple }
        if name.contains("opendns")    { return .teal }
        if name.contains("adguard")    { return .pink }
        if name.contains("system")     { return Color(nsColor: .secondaryLabelColor) }
        if name.contains("gateway") || name.contains("router") { return .green }
        // Custom resolvers: assign from palette by name hash
        let colors: [Color] = [.indigo, .mint, .yellow, .red, .brown]
        let idx = abs(resolverName.hashValue) % colors.count
        return colors[idx]
    }

    private var dnsResolverNames: [String] {
        Array(Set(loader.dnsPoints.map(\.targetLabel))).sorted()
    }

    private var dnsCard: some View {
        ChartCard(title: "DNS Latency",
                  subtitle: "Round-trip time per resolver (ms) — failures shown as gaps") {
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(loader.dnsPoints) { p in
                        LineMark(x: .value("Time", p.timestamp),
                                 y: .value("ms", p.value))
                            .foregroundStyle(by: .value("Resolver", p.targetLabel))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .symbolSize(30)
                    }
                }
                .chartForegroundStyleScale(
                    domain: dnsResolverNames,
                    range:  dnsResolverNames.map { dnsColor(for: $0) }
                )
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    }
                }
                .frame(height: 180)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        hoverOverlay(proxy: proxy, geometry: geo,
                                     points: loader.dnsPoints, unit: "ms",
                                     overrideColorMap: dnsColorMap)
                    }
                }

                // Legend below the chart
                HStack(spacing: 12) {
                    ForEach(dnsResolverNames, id: \.self) { name in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(dnsColor(for: name))
                                .frame(width: 12, height: 3)
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Speedtest Card

    private var speedtestCard: some View {
        ChartCard(title: "Bandwidth",
                  subtitle: "Download and upload speed from speed tests (Mbps)") {
            if loader.speedtestPoints.isEmpty {
                emptyView(icon: "bolt.fill", message: "No bandwidth tests recorded")
            } else {
                let dlPoints  = loader.speedtestPoints.map { ChartPoint(timestamp: $0.timestamp, value: $0.downloadMbps, targetLabel: "Download") }
                let ulPoints  = loader.speedtestPoints.map { ChartPoint(timestamp: $0.timestamp, value: $0.uploadMbps,   targetLabel: "Upload") }
                let allPoints = dlPoints + ulPoints
                let peak      = allPoints.map(\.value).max() ?? 100
                let yMax      = max(peak * 1.2, bandwidthYellowMbps * 1.5)
                let stColorMap: [String: Color] = ["Download": .blue, "Upload": .orange]
                VStack(alignment: .leading, spacing: 6) {
                    Chart {
                        // Threshold reference lines
                        RuleMark(y: .value("Yellow", bandwidthYellowMbps))
                            .foregroundStyle(Color.orange.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("Red", bandwidthRedMbps))
                            .foregroundStyle(Color.red.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        // Lines + point marks (speedtests are sparse)
                        ForEach(dlPoints) { p in
                            LineMark(x: .value("Time", p.timestamp), y: .value("Mbps", p.value))
                                .foregroundStyle(Color.blue)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("Time", p.timestamp), y: .value("Mbps", p.value))
                                .foregroundStyle(Color.blue)
                                .symbolSize(50)
                        }
                        ForEach(ulPoints) { p in
                            LineMark(x: .value("Time", p.timestamp), y: .value("Mbps", p.value))
                                .foregroundStyle(Color.orange)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("Time", p.timestamp), y: .value("Mbps", p.value))
                                .foregroundStyle(Color.orange)
                                .symbolSize(50)
                        }
                    }
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                            AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                            AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                        }
                    }
                    .chartYScale(domain: 0...yMax)
                    .frame(height: 200)
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            hoverOverlay(proxy: proxy, geometry: geo,
                                         points: allPoints, unit: "Mbps",
                                         overrideColorMap: stColorMap)
                        }
                    }

                    // ISP info from most recent test
                    if let latest = loader.speedtestPoints.last, !latest.isp.isEmpty {
                        Text("ISP: \(latest.isp)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Legend
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue).frame(width: 12, height: 3)
                            Text("Download").font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 12, height: 3)
                            Text("Upload").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Hourly Pattern Card

    /// Bar chart showing historical average RTT by hour-of-day from the last 30 days.
    /// Bars are coloured green → orange → red based on how they compare to the latency thresholds.
    private var hourlyPatternCard: some View {
        ChartCard(title: "Daily Pattern",
                  subtitle: "Average latency by time of day — last 30 days") {
            let hours   = loader.hourlyRTTAverages.sorted { $0.key < $1.key }
            let maxRTT  = hours.map(\.value).max() ?? thresholds.latencyRedMs
            let yMax    = max(maxRTT * 1.2, thresholds.latencyYellowMs * 2)
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    RuleMark(y: .value("Yellow", thresholds.latencyYellowMs))
                        .foregroundStyle(Color.orange.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    RuleMark(y: .value("Red", thresholds.latencyRedMs))
                        .foregroundStyle(Color.red.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    ForEach(hours, id: \.key) { hour, avg in
                        BarMark(
                            x: .value("Hour", hourLabel(hour)),
                            y: .value("Avg RTT ms", avg)
                        )
                        .foregroundStyle(barColor(avg))
                        .cornerRadius(3)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) { v in
                        AxisValueLabel().font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisValueLabel().font(.caption).foregroundStyle(.secondary)
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    }
                }
                .chartYScale(domain: 0...yMax)
                .frame(height: 160)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let loc):
                                    hoveredHourLabel = proxy.value(atX: loc.x - origin.x, as: String.self)
                                case .ended:
                                    hoveredHourLabel = nil
                                }
                            }
                        if let label = hoveredHourLabel,
                           let avg   = hours.first(where: { hourLabel($0.key) == label })?.value,
                           let xPos  = proxy.position(forX: label) {
                            let xInView = xPos + origin.x
                            // Cursor line
                            Path { p in
                                p.move(to: CGPoint(x: xInView, y: 0))
                                p.addLine(to: CGPoint(x: xInView, y: geo.size.height))
                            }
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            // Tooltip
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.1f ms", avg))
                                    .font(.caption)
                                    .bold()
                                    .foregroundStyle(barColor(avg))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .position(
                                x: xInView < geo.size.width / 2
                                    ? min(xInView + 60, geo.size.width - 60)
                                    : max(xInView - 60, 60),
                                y: origin.y + 28
                            )
                        }
                    }
                }

                HStack(spacing: 12) {
                    legendDot(.green,  "Normal")
                    legendDot(.orange, "Elevated")
                    legendDot(.red,    "High")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0:  return "12 AM"
        case 12: return "12 PM"
        case let h where h < 12: return "\(h) AM"
        default: return "\(hour - 12) PM"
        }
    }

    private func barColor(_ avg: Double) -> Color {
        if avg >= thresholds.latencyRedMs    { return .red }
        if avg >= thresholds.latencyYellowMs { return .orange }
        return .green
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    // MARK: - Incident List

    private var incidentList: some View {
        ChartCard(title: "Incidents", subtitle: "Network disturbances in this period") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(loader.incidents) { inc in
                    HStack(spacing: 8) {
                        Circle().fill(incidentColor(inc)).frame(width: 8, height: 8)
                        Text(incidentDescription(inc))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        if inc.isActive {
                            Text("Active").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func incidentColor(_ inc: SQLiteStore.IncidentRow) -> Color {
        inc.peakSeverityRaw >= 2 ? .red : .orange
    }

    private static let _incidentFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm MMM d"
        return f
    }()

    private func incidentDescription(_ inc: SQLiteStore.IncidentRow) -> String {
        let start = Self._incidentFmt.string(from: inc.startedAt)
        if let end = inc.endedAt {
            let dur = Int(end.timeIntervalSince(inc.startedAt))
            return "\(start) · \(inc.cause) · \(dur)s"
        }
        return "\(start) · \(inc.cause) · ongoing"
    }
}

// MARK: - ChartCard

struct ChartCard<Content: View>: View {
    let title:    String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3)
                    .bold()
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}
