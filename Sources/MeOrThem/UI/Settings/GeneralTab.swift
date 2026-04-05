import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, enabled in
                        loginError = nil
                        do {
                            try LaunchAtLoginHelper.set(enabled)
                        } catch {
                            loginError = error.localizedDescription
                            settings.launchAtLogin = !enabled
                        }
                    }

                if let err = loginError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Monitoring") {
                Picker("Poll interval", selection: $settings.pollIntervalSecs) {
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("60 seconds").tag(60.0)
                }
                .pickerStyle(.menu)
            }

            Section("Bandwidth Test") {
                Picker("Auto-test interval", selection: $settings.bandwidthScheduleHours) {
                    Text("Disabled").tag(0.0)
                    Text("Every 1 hour").tag(1.0)
                    Text("Every 3 hours").tag(3.0)
                    Text("Every 6 hours").tag(6.0)
                    Text("Every 12 hours").tag(12.0)
                    Text("Every 24 hours").tag(24.0)
                }
                .pickerStyle(.menu)
                Text("Latency polling is paused while a bandwidth test runs.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Show bandwidth bar in menu bar", isOn: $settings.showBandwidthBar)
                    .help("Displays a thin colored bar under the status icon reflecting download speed after a bandwidth test.")
                if settings.showBandwidthBar {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Red below")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                TextField("Mbps", value: $settings.bandwidthBarRedMbps, format: .number)
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                                Text("Mbps").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Yellow below")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                TextField("Mbps", value: $settings.bandwidthBarYellowMbps, format: .number)
                                    .frame(width: 60)
                                    .textFieldStyle(.roundedBorder)
                                Text("Mbps").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Appearance") {
                Toggle("Show latency in menu bar", isOn: $settings.showLatencyInMenubar)
                    .help("Displays the current average latency (e.g. 42ms) next to the status icon.")

                Picker("Icon style", selection: $settings.alwaysShowBarChart) {
                    Label {
                        Text("Circle")
                    } icon: {
                        Canvas { ctx, size in
                            let margin: CGFloat = 1.5
                            let rect = CGRect(x: margin, y: margin,
                                              width: size.width - margin * 2,
                                              height: size.height - margin * 2)
                            ctx.stroke(Path(ellipseIn: rect),
                                       with: .color(.green),
                                       lineWidth: 1.5)
                        }
                        .frame(width: 14, height: 14)
                    }
                    .tag(false)

                    Label {
                        Text("Bar chart")
                    } icon: {
                        Canvas { ctx, size in
                            let barW: CGFloat = (size.width - 4) / 3 - 0.5
                            let colors: [Color] = [.green, .orange, .red]
                            let heights: [CGFloat] = [size.height - 2, (size.height - 2) * 0.6, (size.height - 2) * 0.3]
                            for i in 0..<3 {
                                let x = 1 + CGFloat(i) * (barW + 1)
                                let h = heights[i]
                                let rect = CGRect(x: x, y: size.height - h - 1, width: barW, height: h)
                                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(colors[i]))
                            }
                        }
                        .frame(width: 14, height: 14)
                    }
                    .tag(true)
                }
                .pickerStyle(.radioGroup)
                Picker("Color theme", selection: $settings.colorTheme) {
                    ForEach(ColorTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Data") {
                Toggle("Daily log rotation", isOn: $settings.enableLogRotation)
                    .help("Saves a daily CSV snapshot to ~/Library/Logs/MeOrThem/. Keeps the last 30 days.")
                if settings.enableLogRotation {
                    Text("Saved to ~/Library/Logs/MeOrThem/")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }
}

// MARK: - Launch at Login helper using SMAppService (macOS 13+)
import ServiceManagement

enum LaunchAtLoginHelper {
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
