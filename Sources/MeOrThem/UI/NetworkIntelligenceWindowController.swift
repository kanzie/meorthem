import AppKit
import SwiftUI
@preconcurrency import MeOrThemCore

// MARK: - Window controller

final class NetworkIntelligenceWindowController: NSWindowController {

    private let db:               SQLiteStore
    private let settings:         AppSettings
    private let metricStore:      MetricStore

    init(db: SQLiteStore, settings: AppSettings, metricStore: MetricStore) {
        self.db          = db
        self.settings    = settings
        self.metricStore = metricStore

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        window.title                = "Network Intelligence"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate    = false
        window.collectionBehavior   = [.moveToActiveSpace, .participatesInCycle]
        window.minSize              = NSSize(width: 820, height: 540)
        window.center()

        super.init(window: window)

        let view = NetworkIntelligenceView(db: db, settings: settings, metricStore: metricStore)
        window.contentViewController = NSHostingController(rootView: view)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Tab enum

private enum IntelligenceTab: String, CaseIterable, Identifiable {
    case graphs    = "Graphs"
    case profiles  = "Profiles"
    case analysis  = "Analysis"
    case incidents = "Incidents"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .graphs:    return "chart.xyaxis.line"
        case .profiles:  return "network"
        case .analysis:  return "magnifyingglass.circle"
        case .incidents: return "exclamationmark.triangle"
        }
    }

    var subtitle: String {
        switch self {
        case .graphs:    return "Latency, loss, jitter & WiFi"
        case .profiles:  return "Per-network probe settings"
        case .analysis:  return "Pattern detection & findings"
        case .incidents: return "Outage & degradation history"
        }
    }
}

// MARK: - Sidebar row

private struct IntelligenceSidebarRow: View {
    let tab:        IntelligenceTab
    let isSelected: Bool
    let action:     () -> Void

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
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary)
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

// MARK: - Main view

private struct NetworkIntelligenceView: View {

    let db:          SQLiteStore
    let settings:    AppSettings
    let metricStore: MetricStore

    @State private var selectedTab:     IntelligenceTab = .graphs
    @State private var sessions:        [SQLiteStore.NetworkSessionRow] = []
    @State private var selectedSession: SQLiteStore.NetworkSessionRow?
    @State private var activeSessionID: UUID?

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {

            // ── Sidebar ────────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {

                // Profile dropdown
                profilePicker
                    .padding(.horizontal, 10)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                Divider()
                    .padding(.bottom, 4)

                // Tab navigation
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(IntelligenceTab.allCases) { tab in
                        IntelligenceSidebarRow(tab: tab,
                                               isSelected: selectedTab == tab,
                                               action: { selectedTab = tab })
                    }
                }
                .padding(.horizontal, 8)

                Spacer()
            }
            .frame(width: 205)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // ── Tab content ────────────────────────────────────────────────────
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await loadSessions() }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .graphs:
            MetricsChartsView(
                db:                  db,
                targets:             settings.pingTargets,
                thresholds:          settings.thresholds,
                preloadedSession:    selectedSession
            )

        case .profiles:
            ConnectionProfilesView(
                db:                     db,
                highlightedFingerprint: selectedSession?.fingerprint
            )

        case .analysis:
            NetworkAnalysisView(
                sqliteStore:    db,
                settings:       settings,
                initialSession: selectedSession
            )
            // Re-initialise when the selected session changes so the view reflects
            // the new selection rather than keeping stale internal state.
            .id(selectedSession?.id)

        case .incidents:
            IncidentHistoryView(
                sqliteStore:  db,
                onShowCharts: { _, _ in selectedTab = .graphs }
            )
        }
    }

    // MARK: - Profile picker

    private var profilePicker: some View {
        Menu {
            if sessions.isEmpty {
                Text("No sessions recorded yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupedSessions, id: \.id) { group in
                    Section(group.label) {
                        ForEach(group.sessions) { session in
                            Button {
                                selectedSession = session
                            } label: {
                                if session.id == activeSessionID {
                                    Label(session.displayName + " (Active)", systemImage: "wifi")
                                } else {
                                    Text(sessionMenuLabel(session))
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: connectionIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(selectedSession?.displayName ?? "No sessions")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if selectedSession?.id == activeSessionID {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green))
                        }
                    }
                    if let session = selectedSession {
                        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var connectionIcon: String {
        guard let session = selectedSession else { return "network" }
        switch session.connectionType {
        case "wifi":     return "wifi"
        case "ethernet": return "cable.connector"
        case "vpn":      return "lock.shield"
        default:         return "network"
        }
    }

    private func sessionMenuLabel(_ session: SQLiteStore.NetworkSessionRow) -> String {
        let timeStr = Self.timeFmt.string(from: session.startedAt)
        return "\(session.displayName) — \(timeStr)"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    /// Sessions grouped by calendar day (descending), with "Today" / "Yesterday" labels.
    private var groupedSessions: [(id: Date, label: String, sessions: [SQLiteStore.NetworkSessionRow])] {
        let calendar = Calendar.current
        let today     = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var result: [(id: Date, label: String, sessions: [SQLiteStore.NetworkSessionRow])] = []
        var curDay:      Date?
        var curLabel     = ""
        var curSessions: [SQLiteStore.NetworkSessionRow] = []

        for session in sessions {   // already sorted descending
            let day = calendar.startOfDay(for: session.startedAt)
            if day != curDay {
                if let d = curDay, !curSessions.isEmpty {
                    result.append((d, curLabel, curSessions))
                }
                curDay      = day
                curLabel    = day == today ? "Today" : day == yesterday ? "Yesterday" : Self.dayFmt.string(from: day)
                curSessions = [session]
            } else {
                curSessions.append(session)
            }
        }
        if let d = curDay, !curSessions.isEmpty { result.append((d, curLabel, curSessions)) }
        return result
    }

    // MARK: - Data loading

    private func loadSessions() async {
        let db             = self.db
        let currentSessID  = metricStore.currentSessionID
        let rows = await Task.detached(priority: .userInitiated) {
            db.sessionsInRange(from: .distantPast, to: .distantFuture)
        }.value

        sessions        = rows.sorted { $0.startedAt > $1.startedAt }
        activeSessionID = currentSessID

        if selectedSession == nil {
            // Default to the currently active session; fall back to the most recent.
            selectedSession = sessions.first { $0.id == currentSessID } ?? sessions.first
        }
    }
}
