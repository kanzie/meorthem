import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general    = "General"
    case targets    = "Targets"
    case thresholds = "Thresholds"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:    return "gear"
        case .targets:    return "server.rack"
        case .thresholds: return "dial.medium"
        }
    }

    var subtitle: String {
        switch self {
        case .general:    return "Startup, monitoring & appearance"
        case .targets:    return "Hosts to ping"
        case .thresholds: return "Alert levels & evaluation windows"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        Text(tab.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } icon: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 185, ideal: 200, max: 220)
            .navigationTitle("")
        } detail: {
            Group {
                switch selectedTab {
                case .general:    GeneralTab()
                case .targets:    TargetsTab()
                case .thresholds: ThresholdsTab()
                }
            }
            .frame(minWidth: 380, minHeight: 440)
            .navigationTitle(selectedTab.rawValue)
        }
        .frame(width: 660, height: 520)
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
