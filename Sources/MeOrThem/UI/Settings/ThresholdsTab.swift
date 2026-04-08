import SwiftUI

struct ThresholdsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Latency") {
                recommendedRow("Recommended value under 100 ms (video calls) · 50 ms (gaming)")
                thresholdRow("Yellow above",
                             value: yellowCapped($settings.thresholds.latencyYellowMs,
                                                 red: $settings.thresholds.latencyRedMs),
                             unit: "ms", range: 10...500)
                thresholdRow("Red above",
                             value: redClamping($settings.thresholds.latencyRedMs,
                                               yellow: $settings.thresholds.latencyYellowMs),
                             unit: "ms", range: 50...2000)
                windowRow("Evaluation window", value: $settings.latencyWindowSecs)
            }
            Section("Packet Loss") {
                recommendedRow("Recommended value under 1% (video calls) · 0.5% (gaming)")
                thresholdRow("Yellow above",
                             value: yellowCapped($settings.thresholds.lossYellowPct,
                                                 red: $settings.thresholds.lossRedPct),
                             unit: "%", range: 0.1...20)
                thresholdRow("Red above",
                             value: redClamping($settings.thresholds.lossRedPct,
                                               yellow: $settings.thresholds.lossYellowPct),
                             unit: "%", range: 1...50)
                windowRow("Evaluation window", value: $settings.lossWindowSecs)
            }
            Section("Jitter") {
                recommendedRow("Recommended value under 30 ms (video calls) · 15 ms (gaming)")
                thresholdRow("Yellow above",
                             value: yellowCapped($settings.thresholds.jitterYellowMs,
                                                 red: $settings.thresholds.jitterRedMs),
                             unit: "ms", range: 1...200)
                thresholdRow("Red above",
                             value: redClamping($settings.thresholds.jitterRedMs,
                                               yellow: $settings.thresholds.jitterYellowMs),
                             unit: "ms", range: 5...500)
                windowRow("Evaluation window", value: $settings.jitterWindowSecs)
                awdlNoteRow()
            }
            Section("Download Speed (Bandwidth Bar)") {
                recommendedRow("Bar appears in the menu bar icon after a bandwidth test · green ≥ yellow threshold · red below red threshold")
                thresholdRow("Yellow below",
                             value: bwYellow($settings.bandwidthBarYellowMbps,
                                             red: $settings.bandwidthBarRedMbps),
                             unit: "Mbps", range: 10...2000)
                thresholdRow("Red below",
                             value: bwRed($settings.bandwidthBarRedMbps,
                                          yellow: $settings.bandwidthBarYellowMbps),
                             unit: "Mbps", range: 10...2000)
            }

            Section {
                Button("Reset to Defaults") {
                    settings.thresholds = .default
                    settings.bandwidthBarRedMbps    = 10
                    settings.bandwidthBarYellowMbps = 25
                    settings.latencyWindowSecs = 15
                    settings.lossWindowSecs    = 10
                    settings.jitterWindowSecs  = 30
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .padding(8)
    }

    // MARK: - Latency/Loss/Jitter bindings (yellow ≤ red)

    private func yellowCapped(_ yellow: Binding<Double>, red: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { yellow.wrappedValue },
            set: { yellow.wrappedValue = min($0, red.wrappedValue) }
        )
    }

    private func redClamping(_ red: Binding<Double>, yellow: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { red.wrappedValue },
            set: {
                red.wrappedValue    = $0
                yellow.wrappedValue = min(yellow.wrappedValue, $0)
            }
        )
    }

    // MARK: - Bandwidth bindings (yellow ≥ red — higher Mbps = better)

    /// Yellow must stay ≥ red (yellow threshold is the higher "good enough" value).
    private func bwYellow(_ yellow: Binding<Double>, red: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { yellow.wrappedValue },
            set: { yellow.wrappedValue = max($0, red.wrappedValue) }
        )
    }

    /// Red must stay ≤ yellow; if red goes up past yellow, yellow follows.
    private func bwRed(_ red: Binding<Double>, yellow: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { red.wrappedValue },
            set: {
                red.wrappedValue    = $0
                yellow.wrappedValue = max(yellow.wrappedValue, $0)
            }
        )
    }

    // MARK: - Shared row helpers

    private func thresholdRow(_ label: String, value: Binding<Double>,
                               unit: String, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.0f \(unit)", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
    }

    /// Window slider: lower bound clamps to the configured poll interval; upper bound is 300 s.
    private func windowRow(_ label: String, value: Binding<Double>) -> some View {
        let poll = settings.pollIntervalSecs
        let clamped = Binding<Double>(
            get: { Swift.max(value.wrappedValue, poll) },
            set: { value.wrappedValue = Swift.max($0, poll) }
        )
        return HStack {
            Text(label).frame(width: 120, alignment: .leading)
            Slider(value: clamped, in: poll...300)
            Text(String(format: "%.0f s", clamped.wrappedValue))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func awdlNoteRow() -> some View {
        Text("AWDL (Apple Wireless Direct Link — AirDrop, Handoff) performs a channel scan roughly every 60 s, causing a brief jitter spike each time. Keep the evaluation window above 10 s — ideally 30 s or more — to prevent these scans from triggering false alarms.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func recommendedRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
