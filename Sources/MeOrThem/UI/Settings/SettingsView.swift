import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General",    systemImage: "gear") }

            TargetsTab()
                .tabItem { Label("Targets",    systemImage: "server.rack") }

            ThresholdsTab()
                .tabItem { Label("Thresholds", systemImage: "dial.medium") }
        }
        .frame(width: 540, height: 460)
        .preferredColorScheme(colorScheme(for: settings.colorTheme))
    }

    private func colorScheme(for theme: ColorTheme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
