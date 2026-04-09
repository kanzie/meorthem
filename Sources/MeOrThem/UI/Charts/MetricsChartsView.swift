import SwiftUI
import Charts
import MeOrThemCore

// MARK: - Target color palette

private let targetColorPalette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo]

private func targetColor(index: Int) -> Color {
    targetColorPalette[index % targetColorPalette.count]
}

// MARK: - MetricsChartsView

struct MetricsChartsView: View {
    @StateObject private var loader: MetricsDataLoader
    @State private var selectedWindow: TimeWindow = .hour24
    @State private var selectedTargetIndex: Int = 0   // 0 = all

    private let thresholds: Thresholds

    init(db: SQLiteStore, targets: [PingTarget], thresholds: Thresholds) {
        _loader     = StateObject(wrappedValue: MetricsDataLoader(db: db, targets: targets))
        self.thresholds = thresholds
    }

    // Targets to display: all or a single one
    private var visibleTargets: [PingTarget] {
        if selectedTargetIndex == 0 { return loader.targets }
        let idx = selectedTargetIndex - 1
        guard loader.targets.indices.contains(idx) else { return loader.targets }
        return [loader.targets[idx]]
    }

    private var visibleTargetLabels: [String] {
        visibleTargets.map(\.label)
    }

    private var visibleTargetColors: [Color] {
        if selectedTargetIndex == 0 {
            return loader.targets.indices.map { targetColor(index: $0) }
        }
        let idx = selectedTargetIndex - 1
        return [targetColor(index: idx)]
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

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if loader.isLoading {
                loadingView
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        latencyCard
                        lossCard
                        jitterCard
                        if !loader.wifiRSSI.isEmpty {
                            wifiCard
                        }
                        if !loader.incidents.isEmpty {
                            incidentList
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 500)
        .onAppear { loader.load(window: selectedWindow) }
        .onChange(of: selectedWindow) { _, w in loader.load(window: w) }
        .onChange(of: selectedTargetIndex) { _, _ in /* filter is derived, no reload */ }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Network History")
                .font(.headline)

            Spacer()

            if loader.targets.count > 1 {
                Picker("Target", selection: $selectedTargetIndex) {
                    Text("All Targets").tag(0)
                    ForEach(loader.targets.indices, id: \.self) { i in
                        Text(loader.targets[i].label).tag(i + 1)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 160)
            }

            Picker("Window", selection: $selectedWindow) {
                ForEach(TimeWindow.allCases) { w in
                    Text(w.label).tag(w)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            Button {
                loader.load(window: selectedWindow)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Loading / Empty

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading data…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Latency Card

    private var latencyCard: some View {
        ChartCard(
            title: "Latency",
            subtitle: "Round-trip time in milliseconds"
        ) {
            if filteredLatency.isEmpty {
                emptyView(icon: "waveform.path.ecg", message: "No latency data for this period")
            } else {
                Chart {
                    // Threshold bands
                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("Y0", 0),
                        yEnd:   .value("YG", thresholds.latencyYellowMs)
                    )
                    .foregroundStyle(Color.green.opacity(0.08))

                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("YG", thresholds.latencyYellowMs),
                        yEnd:   .value("YR", thresholds.latencyRedMs)
                    )
                    .foregroundStyle(Color.orange.opacity(0.08))

                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("YR", thresholds.latencyRedMs),
                        yEnd:   .value("YMax", maxLatencyY)
                    )
                    .foregroundStyle(Color.red.opacity(0.08))

                    // Threshold lines
                    RuleMark(y: .value("Yellow", thresholds.latencyYellowMs))
                        .foregroundStyle(Color.orange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    RuleMark(y: .value("Red", thresholds.latencyRedMs))
                        .foregroundStyle(Color.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    // Incident markers
                    ForEach(loader.incidents) { inc in
                        RuleMark(x: .value("Incident", inc.startedAt))
                            .foregroundStyle(incidentColor(inc).opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    }

                    // Data lines
                    ForEach(filteredLatency) { p in
                        LineMark(
                            x: .value("Time", p.timestamp),
                            y: .value("RTT ms", p.value)
                        )
                        .foregroundStyle(by: .value("Target", p.targetLabel))
                        .interpolationMethod(.catmullRom)
                    }
                }
                .chartForegroundStyleScale(
                    domain: visibleTargetLabels,
                    range: visibleTargetColors
                )
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartYScale(domain: 0...maxLatencyY)
                .frame(height: 200)
            }
        }
    }

    private var maxLatencyY: Double {
        let peak = filteredLatency.map(\.value).max() ?? 0
        return max(peak * 1.2, thresholds.latencyRedMs * 1.5)
    }

    // MARK: - Loss Card

    private var lossCard: some View {
        ChartCard(
            title: "Packet Loss",
            subtitle: "Percentage of pings lost"
        ) {
            if filteredLoss.isEmpty {
                emptyView(icon: "exclamationmark.triangle", message: "No loss data for this period")
            } else {
                Chart {
                    // Threshold bands
                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("Y0", 0),
                        yEnd:   .value("YG", thresholds.lossYellowPct)
                    )
                    .foregroundStyle(Color.green.opacity(0.08))

                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("YG", thresholds.lossYellowPct),
                        yEnd:   .value("YR", thresholds.lossRedPct)
                    )
                    .foregroundStyle(Color.orange.opacity(0.08))

                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("YR", thresholds.lossRedPct),
                        yEnd:   .value("YMax", maxLossY)
                    )
                    .foregroundStyle(Color.red.opacity(0.08))

                    // Threshold lines
                    RuleMark(y: .value("Yellow", thresholds.lossYellowPct))
                        .foregroundStyle(Color.orange.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    RuleMark(y: .value("Red", thresholds.lossRedPct))
                        .foregroundStyle(Color.red.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    // Incident markers
                    ForEach(loader.incidents) { inc in
                        RuleMark(x: .value("Incident", inc.startedAt))
                            .foregroundStyle(incidentColor(inc).opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    }

                    // Data
                    ForEach(filteredLoss) { p in
                        AreaMark(
                            x:      .value("Time", p.timestamp),
                            yStart: .value("Zero", 0),
                            yEnd:   .value("Loss %", p.value)
                        )
                        .foregroundStyle(by: .value("Target", p.targetLabel))
                        .opacity(0.25)

                        LineMark(
                            x: .value("Time", p.timestamp),
                            y: .value("Loss %", p.value)
                        )
                        .foregroundStyle(by: .value("Target", p.targetLabel))
                    }
                }
                .chartForegroundStyleScale(
                    domain: visibleTargetLabels,
                    range: visibleTargetColors
                )
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartYScale(domain: 0...maxLossY)
                .frame(height: 160)
            }
        }
    }

    private var maxLossY: Double {
        let peak = filteredLoss.map(\.value).max() ?? 0
        return max(peak * 1.2, thresholds.lossRedPct * 2)
    }

    // MARK: - Jitter Card

    private var jitterCard: some View {
        ChartCard(
            title: "Jitter",
            subtitle: "Variation in round-trip time"
        ) {
            if filteredJitter.isEmpty {
                emptyView(icon: "waveform", message: "No jitter data for this period")
            } else {
                Chart {
                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("Y0", 0),
                        yEnd:   .value("YG", thresholds.jitterYellowMs)
                    )
                    .foregroundStyle(Color.green.opacity(0.08))

                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("YG", thresholds.jitterYellowMs),
                        yEnd:   .value("YR", thresholds.jitterRedMs)
                    )
                    .foregroundStyle(Color.orange.opacity(0.08))

                    RectangleMark(
                        xStart: .value("Start", loader.rangeStart),
                        xEnd:   .value("End",   loader.rangeEnd),
                        yStart: .value("YR", thresholds.jitterRedMs),
                        yEnd:   .value("YMax", maxJitterY)
                    )
                    .foregroundStyle(Color.red.opacity(0.08))

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
                        AreaMark(
                            x:      .value("Time", p.timestamp),
                            yStart: .value("Zero", 0),
                            yEnd:   .value("Jitter ms", p.value)
                        )
                        .foregroundStyle(by: .value("Target", p.targetLabel))
                        .opacity(0.25)

                        LineMark(
                            x: .value("Time", p.timestamp),
                            y: .value("Jitter ms", p.value)
                        )
                        .foregroundStyle(by: .value("Target", p.targetLabel))
                    }
                }
                .chartForegroundStyleScale(
                    domain: visibleTargetLabels,
                    range: visibleTargetColors
                )
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartYScale(domain: 0...maxJitterY)
                .frame(height: 160)
            }
        }
    }

    private var maxJitterY: Double {
        let peak = filteredJitter.map(\.value).max() ?? 0
        return max(peak * 1.2, thresholds.jitterRedMs * 1.5)
    }

    // MARK: - WiFi Card

    private var wifiCard: some View {
        ChartCard(
            title: "WiFi Signal",
            subtitle: "RSSI in dBm — higher (less negative) is better"
        ) {
            Chart {
                // Quality bands: good above -67, fair -67 to -80, poor below -80
                RectangleMark(
                    xStart: .value("Start", loader.rangeStart),
                    xEnd:   .value("End",   loader.rangeEnd),
                    yStart: .value("Y0",  -67),
                    yEnd:   .value("YTop", 0)
                )
                .foregroundStyle(Color.green.opacity(0.08))

                RectangleMark(
                    xStart: .value("Start", loader.rangeStart),
                    xEnd:   .value("End",   loader.rangeEnd),
                    yStart: .value("Y1",  -80),
                    yEnd:   .value("Y2",  -67)
                )
                .foregroundStyle(Color.orange.opacity(0.08))

                RectangleMark(
                    xStart: .value("Start", loader.rangeStart),
                    xEnd:   .value("End",   loader.rangeEnd),
                    yStart: .value("YBot", -100),
                    yEnd:   .value("Y3",   -80)
                )
                .foregroundStyle(Color.red.opacity(0.08))

                RuleMark(y: .value("Good", -67))
                    .foregroundStyle(Color.green.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                RuleMark(y: .value("Poor", -80))
                    .foregroundStyle(Color.orange.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                ForEach(loader.wifiRSSI) { p in
                    AreaMark(
                        x:      .value("Time", p.timestamp),
                        yStart: .value("Base", -100),
                        yEnd:   .value("RSSI", p.value)
                    )
                    .foregroundStyle(Color.cyan.opacity(0.20))

                    LineMark(
                        x: .value("Time", p.timestamp),
                        y: .value("RSSI", p.value)
                    )
                    .foregroundStyle(Color.cyan)
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartYScale(domain: -100...0)
            .frame(height: 160)
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
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.07), radius: 4, x: 0, y: 2)
    }
}
