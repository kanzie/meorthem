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
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
    }
}

// MARK: - MetricsChartsView

struct MetricsChartsView: View {
    @StateObject private var loader: MetricsDataLoader
    @State private var selectedWindow: TimeWindow = .hour1
    @State private var selectedTargetIndex: Int = 0
    @State private var hoveredDate: Date? = nil

    private let thresholds: Thresholds

    init(db: SQLiteStore, targets: [PingTarget], thresholds: Thresholds) {
        _loader     = StateObject(wrappedValue: MetricsDataLoader(db: db, targets: targets))
        self.thresholds = thresholds
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
                        if !loader.incidents.isEmpty { incidentList }
                    }
                    .padding(20)
                }
            }
        }
        .background(.ultraThinMaterial)
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
        .onAppear { loader.load(window: selectedWindow) }
        .onChange(of: selectedWindow) { _, w in loader.load(window: w) }
        .onChange(of: selectedTargetIndex) { _, _ in /* filter is derived */ }
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

    private var windowPicker: some View {
        Picker("Window", selection: $selectedWindow) {
            ForEach(TimeWindow.allCases) { w in
                Text(w.label).tag(w)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 380)
    }

    // MARK: - Loading / Empty

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading data…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
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

    private func nearestPoints(to date: Date, in points: [ChartPoint]) -> [ChartPoint] {
        let labels = Set(points.map(\.targetLabel))
        return labels.compactMap { label in
            points
                .filter { $0.targetLabel == label }
                .min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) })
        }
        .sorted { $0.targetLabel < $1.targetLabel }
    }

    private func tooltipEntries(for date: Date, in points: [ChartPoint]) -> [(label: String, value: Double, color: Color)] {
        nearestPoints(to: date, in: points).compactMap { p in
            guard let color = colorMap[p.targetLabel] else { return nil }
            return (p.targetLabel, p.value, color)
        }
    }

    // MARK: - Legend

    private func legend(labels: [String], colors: [Color]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(zip(labels, colors)), id: \.0) { label, color in
                HStack(spacing: 4) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Hover overlay builder

    @ViewBuilder
    private func hoverOverlay(proxy: ChartProxy, geometry: GeometryProxy, points: [ChartPoint], unit: String) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    let origin = proxy.plotFrame.map { geometry[$0].origin } ?? .zero
                    if let date: Date = proxy.value(atX: loc.x - origin.x) {
                        hoveredDate = date
                    }
                case .ended:
                    hoveredDate = nil
                }
            }

        if let date = hoveredDate {
            let snapped = nearestPoints(to: date, in: points)
            if let first = snapped.first, let xPos = proxy.position(forX: first.timestamp) {
                let origin = proxy.plotFrame.map { geometry[$0].origin } ?? .zero
                let xInView = xPos + origin.x

                // Vertical cursor line
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .offset(x: xInView - geometry.size.width / 2)

                // Tooltip card
                let entries = tooltipEntries(for: date, in: points)
                HoverTooltip(date: first.timestamp, entries: entries, unit: unit)
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

    // MARK: - Latency Card

    private var latencyCard: some View {
        ChartCard(title: "Latency", subtitle: "Round-trip time in milliseconds") {
            if filteredLatency.isEmpty {
                emptyView(icon: "waveform.path.ecg", message: "No latency data for this period")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Chart {
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("Y0", 0),                yEnd: .value("YG", thresholds.latencyYellowMs))
                            .foregroundStyle(Color.green.opacity(0.06))
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("YG", thresholds.latencyYellowMs), yEnd: .value("YR", thresholds.latencyRedMs))
                            .foregroundStyle(Color.orange.opacity(0.06))
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("YR", thresholds.latencyRedMs), yEnd: .value("YMax", maxLatencyY))
                            .foregroundStyle(Color.red.opacity(0.06))

                        RuleMark(y: .value("Yellow", thresholds.latencyYellowMs))
                            .foregroundStyle(Color.orange.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("Red", thresholds.latencyRedMs))
                            .foregroundStyle(Color.red.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        ForEach(loader.incidents) { inc in
                            RuleMark(x: .value("Incident", inc.startedAt))
                                .foregroundStyle(incidentColor(inc).opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        }

                        ForEach(filteredLatency) { p in
                            LineMark(x: .value("Time", p.timestamp), y: .value("RTT ms", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                                .interpolationMethod(.catmullRom)
                        }

                        if let date = hoveredDate {
                            ForEach(nearestPoints(to: date, in: filteredLatency)) { p in
                                PointMark(x: .value("Time", p.timestamp), y: .value("RTT ms", p.value))
                                    .symbolSize(72)
                                    .foregroundStyle(colorMap[p.targetLabel] ?? .primary)
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: visibleTargetLabels, range: visibleTargetColors)
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
                            hoverOverlay(proxy: proxy, geometry: geo, points: filteredLatency, unit: "ms")
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

    // MARK: - Loss Card

    private var lossCard: some View {
        ChartCard(title: "Packet Loss", subtitle: "Percentage of pings lost") {
            if filteredLoss.isEmpty {
                emptyView(icon: "exclamationmark.triangle", message: "No loss data for this period")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Chart {
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("Y0", 0),                yEnd: .value("YG", thresholds.lossYellowPct))
                            .foregroundStyle(Color.green.opacity(0.06))
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("YG", thresholds.lossYellowPct), yEnd: .value("YR", thresholds.lossRedPct))
                            .foregroundStyle(Color.orange.opacity(0.06))
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("YR", thresholds.lossRedPct), yEnd: .value("YMax", maxLossY))
                            .foregroundStyle(Color.red.opacity(0.06))

                        RuleMark(y: .value("Yellow", thresholds.lossYellowPct))
                            .foregroundStyle(Color.orange.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("Red", thresholds.lossRedPct))
                            .foregroundStyle(Color.red.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        ForEach(loader.incidents) { inc in
                            RuleMark(x: .value("Incident", inc.startedAt))
                                .foregroundStyle(incidentColor(inc).opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        }

                        ForEach(filteredLoss) { p in
                            AreaMark(x: .value("Time", p.timestamp), yStart: .value("Zero", 0), yEnd: .value("Loss %", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                                .opacity(0.25)
                            LineMark(x: .value("Time", p.timestamp), y: .value("Loss %", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                        }

                        if let date = hoveredDate {
                            ForEach(nearestPoints(to: date, in: filteredLoss)) { p in
                                PointMark(x: .value("Time", p.timestamp), y: .value("Loss %", p.value))
                                    .symbolSize(72)
                                    .foregroundStyle(colorMap[p.targetLabel] ?? .primary)
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: visibleTargetLabels, range: visibleTargetColors)
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
                            hoverOverlay(proxy: proxy, geometry: geo, points: filteredLoss, unit: "%")
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
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("Y0", 0),                yEnd: .value("YG", thresholds.jitterYellowMs))
                            .foregroundStyle(Color.green.opacity(0.06))
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("YG", thresholds.jitterYellowMs), yEnd: .value("YR", thresholds.jitterRedMs))
                            .foregroundStyle(Color.orange.opacity(0.06))
                        RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                      yStart: .value("YR", thresholds.jitterRedMs), yEnd: .value("YMax", maxJitterY))
                            .foregroundStyle(Color.red.opacity(0.06))

                        RuleMark(y: .value("Yellow", thresholds.jitterYellowMs))
                            .foregroundStyle(Color.orange.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        RuleMark(y: .value("Red", thresholds.jitterRedMs))
                            .foregroundStyle(Color.red.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        ForEach(loader.incidents) { inc in
                            RuleMark(x: .value("Incident", inc.startedAt))
                                .foregroundStyle(incidentColor(inc).opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        }

                        ForEach(filteredJitter) { p in
                            AreaMark(x: .value("Time", p.timestamp), yStart: .value("Zero", 0), yEnd: .value("Jitter ms", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                                .opacity(0.25)
                            LineMark(x: .value("Time", p.timestamp), y: .value("Jitter ms", p.value))
                                .foregroundStyle(by: .value("Target", p.targetLabel))
                        }

                        if let date = hoveredDate {
                            ForEach(nearestPoints(to: date, in: filteredJitter)) { p in
                                PointMark(x: .value("Time", p.timestamp), y: .value("Jitter ms", p.value))
                                    .symbolSize(72)
                                    .foregroundStyle(colorMap[p.targetLabel] ?? .primary)
                            }
                        }
                    }
                    .chartForegroundStyleScale(domain: visibleTargetLabels, range: visibleTargetColors)
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
                            hoverOverlay(proxy: proxy, geometry: geo, points: filteredJitter, unit: "ms")
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
                    RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                  yStart: .value("Y0", -67), yEnd: .value("YTop", 0))
                        .foregroundStyle(Color.green.opacity(0.06))
                    RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                  yStart: .value("Y1", -80), yEnd: .value("Y2", -67))
                        .foregroundStyle(Color.orange.opacity(0.06))
                    RectangleMark(xStart: .value("S", loader.rangeStart), xEnd: .value("E", loader.rangeEnd),
                                  yStart: .value("YBot", -100), yEnd: .value("Y3", -80))
                        .foregroundStyle(Color.red.opacity(0.06))

                    RuleMark(y: .value("Good", -67))
                        .foregroundStyle(Color.green.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    RuleMark(y: .value("Poor", -80))
                        .foregroundStyle(Color.orange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    ForEach(loader.wifiRSSI) { p in
                        AreaMark(x: .value("Time", p.timestamp), yStart: .value("Base", -100), yEnd: .value("RSSI", p.value))
                            .foregroundStyle(Color.cyan.opacity(0.20))
                        LineMark(x: .value("Time", p.timestamp), y: .value("RSSI", p.value))
                            .foregroundStyle(Color.cyan)
                    }

                    if let date = hoveredDate {
                        ForEach(nearestPoints(to: date, in: loader.wifiRSSI)) { p in
                            PointMark(x: .value("Time", p.timestamp), y: .value("RSSI", p.value))
                                .symbolSize(72)
                                .foregroundStyle(Color.cyan)
                        }
                    }
                }
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
                        hoverOverlay(proxy: proxy, geometry: geo, points: loader.wifiRSSI, unit: "dBm")
                    }
                }
            }
        }
    }

    // MARK: - Incident List

    private var incidentList: some View {
        ChartCard(title: "Incidents", subtitle: "Network disturbances in this period") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(loader.incidents) { inc in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(incidentColor(inc))
                            .frame(width: 8, height: 8)
                        Text(incidentDescription(inc))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        if inc.isActive {
                            Text("Active")
                                .font(.caption2)
                                .foregroundStyle(.orange)
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

    private func incidentDescription(_ inc: SQLiteStore.IncidentRow) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm MMM d"
        let start = fmt.string(from: inc.startedAt)
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
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
    }
}
