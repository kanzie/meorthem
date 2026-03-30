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

            Section("Appearance") {
                Toggle("Always show bar chart", isOn: $settings.alwaysShowBarChart)
                Picker("Color theme", selection: $settings.colorTheme) {
                    ForEach(ColorTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
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
