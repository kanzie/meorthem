import SwiftUI
import MeOrThemCore

struct GeneralTab: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var loginError: String?
    @State private var isUpdatingLogin = false
    @State private var showAdvancedData = false
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

    private static let logDirURL: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/MeOrThem", isDirectory: true)
    }()

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, enabled in
                        guard !isUpdatingLogin else { return }
                        isUpdatingLogin = true
                        defer { isUpdatingLogin = false }
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

                Picker("On battery", selection: $settings.batteryBehavior) {
                    ForEach(BatteryBehavior.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .help("Controls monitoring behaviour when your Mac is running on battery power.")
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

                if settings.bandwidthScheduleHours > 0 {
                    Toggle("Quiet hours", isOn: $settings.bandwidthQuietHoursEnabled)
                        .help("Suppress automatic bandwidth tests during the specified hours.")
                    if settings.bandwidthQuietHoursEnabled {
                        HStack(spacing: 8) {
                            Text("From")
                            Picker("", selection: $settings.bandwidthQuietHoursStart) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(hourLabel(h)).tag(h)
                                }
                            }
                            .frame(width: 90)
                            .labelsHidden()
                            Text("to")
                            Picker("", selection: $settings.bandwidthQuietHoursEnd) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(hourLabel(h)).tag(h)
                                }
                            }
                            .frame(width: 90)
                            .labelsHidden()
                        }
                        .padding(.leading, 16)
                        Text("Tests scheduled to fire during this window are skipped and run at the next interval.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Latency polling is paused while a bandwidth test runs.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Toggle("Save CSV log files", isOn: $settings.enableLogRotation)
                    .help("Appends one row per poll tick to a dated CSV file in ~/Library/Logs/MeOrThem/. Useful for importing into spreadsheets or external monitoring tools.")

                if settings.enableLogRotation {
                    HStack {
                        Text("~/Library/Logs/MeOrThem/")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(Self.logDirURL)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                Text("Network data is always stored locally in a database regardless of this setting.")
                    .font(.caption).foregroundStyle(.secondary)

                DisclosureGroup(isExpanded: $showAdvancedData) {
                    LabeledContent("Raw data") {
                        HStack(spacing: 4) {
                            TextField("", value: $settings.rawRetentionDays, format: .number)
                                .frame(width: 48)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: settings.rawRetentionDays) { _, v in
                                    settings.rawRetentionDays = max(1, min(v, 365))
                                }
                            Text("days")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Full-resolution samples (one per poll, per target).")
                        .font(.caption).foregroundStyle(.secondary)

                    LabeledContent("Summaries") {
                        HStack(spacing: 4) {
                            TextField("", value: $settings.aggregateRetentionDays, format: .number)
                                .frame(width: 48)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: settings.aggregateRetentionDays) { _, v in
                                    settings.aggregateRetentionDays = max(1, min(v, 3650))
                                }
                            Text("days")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Per-minute averages, created automatically from aged-out raw data.")
                        .font(.caption).foregroundStyle(.secondary)

                    LabeledContent("Incident archive") {
                        HStack(spacing: 4) {
                            TextField("", value: $settings.incidentRetentionDays, format: .number)
                                .frame(width: 48)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .onChange(of: settings.incidentRetentionDays) { _, v in
                                    settings.incidentRetentionDays = max(1, min(v, 3650))
                                }
                            Text("days")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Degradation events shown in Previous Disturbances.")
                        .font(.caption).foregroundStyle(.secondary)
                } label: {
                    HStack {
                        Text("Advanced")
                            .font(.callout)
                        if !showAdvancedData {
                            Text("· \(settings.rawRetentionDays)d raw · \(settings.aggregateRetentionDays)d summaries · \(settings.incidentRetentionDays)d incidents")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Notifications") {
                Toggle("Show banner on connection degradation", isOn: $settings.enableNotificationBanner)
                    .help("Displays a notification banner when your connection degrades to yellow or red.")
                Toggle("Play sound with notifications", isOn: $settings.enableNotificationSound)
                    .help("Plays the default notification sound alongside the banner. Disabled by default.")
                    .disabled(!settings.enableNotificationBanner)
            }

            Section("Metrics Export") {
                Toggle("Enable local metrics endpoint", isOn: $settings.metricsServerEnabled)
                    .help("Serves current metrics at http://localhost:\(settings.metricsServerPort)/metrics (Prometheus) and /metrics.json (JSON)")
                if settings.metricsServerEnabled {
                    HStack(spacing: 8) {
                        Text("Port")
                        TextField("9090", value: $settings.metricsServerPort, format: .number)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: settings.metricsServerPort) { _, v in
                                settings.metricsServerPort = max(1024, min(v, 65535))
                            }
                        Text("http://localhost:\(settings.metricsServerPort)/metrics")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Updates") {
                HStack {
                    Text("Current version: \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check for Updates") {
                        UpdateChecker.shared.checkManually()
                    }
                }
                HStack(spacing: 4) {
                    Text("Last checked:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(updateChecker.lastCheckDescription)
                        .font(.caption)
                        .foregroundStyle(updateChecker.lastCheckDescription.hasPrefix("Failed")
                                         ? .red : .secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .padding(8)
    }
}

// MARK: - Helpers

private func hourLabel(_ hour: Int) -> String {
    let components = DateComponents(hour: hour, minute: 0)
    guard let date = Calendar.current.date(from: components) else {
        return "\(hour):00"
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "h a"
    return fmt.string(from: date)
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
