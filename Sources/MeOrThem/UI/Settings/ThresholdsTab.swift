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
            }
            Section("Download Speed (Bandwidth Bar)") {
                recommendedRow("Bar appears in the menu bar icon after a bandwidth test · green ≥ yellow threshold · red below red threshold")
                thresholdRow("Yellow below",
                             value: bwYellow($settings.bandwidthBarYellowMbps,
                                             red: $settings.bandwidthBarRedMbps),
                             unit: "Mbps", range: 5...500)
                thresholdRow("Red below",
                             value: bwRed($settings.bandwidthBarRedMbps,
                                          yellow: $settings.bandwidthBarYellowMbps),
                             unit: "Mbps", range: 1...200)
            }

            Section {
                Button("Reset to Defaults") {
                    settings.thresholds = .default
                    settings.bandwidthBarRedMbps    = 10
                    settings.bandwidthBarYellowMbps = 25
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

    private func recommendedRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
