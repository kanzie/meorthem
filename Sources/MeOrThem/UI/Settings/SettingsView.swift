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

// MARK: - Sidebar item

private struct SidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .white : Color.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .white : Color.primary)
                    Text(tab.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected
                                         ? Color.white.opacity(0.75)
                                         : Color.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {

            // ── Sidebar ────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarRow(tab: tab,
                               isSelected: selectedTab == tab,
                               action: { selectedTab = tab })
                }
                Spacer()
            }
            .padding(.top, 14)
            .padding(.bottom, 12)
            .padding(.horizontal, 8)
            .frame(width: 195)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // ── Detail ─────────────────────────────────────────────────────────
            Group {
                switch selectedTab {
                case .general:    GeneralTab()
                case .targets:    TargetsTab()
                case .thresholds: ThresholdsTab()
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 660, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
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
