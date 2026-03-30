import SwiftUI

struct ThresholdsTab: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Latency") {
                thresholdRow("Yellow above", value: $settings.thresholds.latencyYellowMs,
                             unit: "ms", range: 10...500)
                thresholdRow("Red above",    value: $settings.thresholds.latencyRedMs,
                             unit: "ms", range: 50...2000)
            }
            Section("Packet Loss") {
                thresholdRow("Yellow above", value: $settings.thresholds.lossYellowPct,
                             unit: "%", range: 0.1...20)
                thresholdRow("Red above",    value: $settings.thresholds.lossRedPct,
                             unit: "%", range: 1...50)
            }
            Section("Jitter") {
                thresholdRow("Yellow above", value: $settings.thresholds.jitterYellowMs,
                             unit: "ms", range: 1...200)
                thresholdRow("Red above",    value: $settings.thresholds.jitterRedMs,
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
