import SwiftUI

struct ThresholdsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Latency") {
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
                thresholdRow("Yellow above",
                             value: yellowCapped($settings.thresholds.jitterYellowMs,
                                                 red: $settings.thresholds.jitterRedMs),
                             unit: "ms", range: 1...200)
                thresholdRow("Red above",
                             value: redClamping($settings.thresholds.jitterRedMs,
                                               yellow: $settings.thresholds.jitterYellowMs),
                             unit: "ms", range: 5...500)
            }

            Section {
                Button("Reset to Defaults") {
                    settings.thresholds = .default
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    /// Yellow binding: value is clamped to ≤ red on every set.
    private func yellowCapped(_ yellow: Binding<Double>, red: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { yellow.wrappedValue },
            set: { yellow.wrappedValue = min($0, red.wrappedValue) }
        )
    }

    /// Red binding: if red drops below yellow, yellow is pulled down with it.
    private func redClamping(_ red: Binding<Double>, yellow: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { red.wrappedValue },
            set: {
                red.wrappedValue    = $0
                yellow.wrappedValue = min(yellow.wrappedValue, $0)
            }
        )
    }

    private func thresholdRow(_ label: String, value: Binding<Double>,
                               unit: String, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 120, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.0f \(unit)", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }
}
