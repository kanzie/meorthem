import AppKit
import SwiftUI
@preconcurrency import MeOrThemCore

// MARK: - Window controller

final class NetworkIntelligenceWindowController: NSWindowController {

    private let db:          SQLiteStore
    private let settings:    AppSettings
    private let metricStore: MetricStore

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
        window.minSize              = NSSize(width: 780, height: 520)
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
    case analysis  = "Analysis"
    case profiles  = "Profiles"
    case incidents = "Incidents"
    var id: String { rawValue }
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

    var body: some View {
        HSplitView {
            sessionSidebar
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)

            VStack(spacing: 0) {
                tabBar
                Divider()
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .task { await loadSessions() }
    }

    // MARK: - Session sidebar

    private var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("NETWORKS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            if sessions.isEmpty {
                Spacer()
                Text("No sessions recorded yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                List(selection: Binding(
                    get:  { selectedSession?.id },
                    set:  { id in selectedSession = sessions.first { $0.id == id } }
                )) {
                    ForEach(groupedSessions, id: \.id) { group in
                        Section(group.label) {
                            ForEach(group.sessions) { session in
                                sessionRow(session)
                                    .tag(session.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func sessionRow(_ session: SQLiteStore.NetworkSessionRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: connectionIcon(for: session))
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(Self.timeFmt.string(from: session.startedAt))
                    if let isp = session.ispName {
                        Text("· \(isp)").lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if session.id == activeSessionID {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        Picker("", selection: $selectedTab) {
            ForEach(IntelligenceTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .graphs:
            MetricsChartsView(
                db:               db,
                targets:          settings.pingTargets,
                thresholds:       settings.thresholds,
                preloadedSession: selectedSession
            )

        case .analysis:
            NetworkAnalysisView(
                sqliteStore:    db,
                settings:       settings,
                initialSession: selectedSession
            )
            .id(selectedSession?.id)

        case .profiles:
            ConnectionProfilesView(
                db:                     db,
                highlightedFingerprint: selectedSession?.fingerprint
            )

        case .incidents:
            IncidentHistoryView(
                sqliteStore:  db,
                onShowCharts: { _, _ in selectedTab = .graphs }
            )
        }
    }

    // MARK: - Helpers

    private func connectionIcon(for session: SQLiteStore.NetworkSessionRow) -> String {
        switch session.connectionType {
        case "wifi":     return "wifi"
        case "ethernet": return "cable.connector"
        case "vpn":      return "lock.shield"
        default:         return "network"
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    private var groupedSessions: [(id: Date, label: String, sessions: [SQLiteStore.NetworkSessionRow])] {
        let calendar  = Calendar.current
        let today     = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var result:      [(id: Date, label: String, sessions: [SQLiteStore.NetworkSessionRow])] = []
        var curDay:      Date?
        var curLabel     = ""
        var curSessions: [SQLiteStore.NetworkSessionRow] = []

        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            if day != curDay {
                if let d = curDay, !curSessions.isEmpty {
                    result.append((d, curLabel, curSessions))
                }
                curDay      = day
                curLabel    = day == today ? "Today"
                            : day == yesterday ? "Yesterday"
                            : Self.dayFmt.string(from: day)
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
        let db            = self.db
        let currentSessID = metricStore.currentSessionID
        let rows = await Task.detached(priority: .userInitiated) {
            db.sessionsInRange(from: .distantPast, to: .distantFuture)
        }.value

        sessions        = rows.sorted { $0.startedAt > $1.startedAt }
        activeSessionID = currentSessID

        if selectedSession == nil {
            selectedSession = sessions.first { $0.id == currentSessID } ?? sessions.first
        }
    }
}
