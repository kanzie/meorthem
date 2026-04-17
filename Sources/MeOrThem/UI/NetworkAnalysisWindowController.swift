import AppKit
import SwiftUI
import MeOrThemCore

final class NetworkAnalysisWindowController: NSWindowController {

    private let sqliteStore: SQLiteStore
    private let settings:    AppSettings

    init(sqliteStore: SQLiteStore, settings: AppSettings) {
        self.sqliteStore = sqliteStore
        self.settings    = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Network Analysis"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        let view = NetworkAnalysisView(sqliteStore: sqliteStore, settings: settings)
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root view

private struct NetworkAnalysisView: View {
    let sqliteStore: SQLiteStore
    let settings:    AppSettings

    @State private var sessions:        [SQLiteStore.NetworkSessionRow] = []
    @State private var selectedSession: SQLiteStore.NetworkSessionRow?
    @State private var findings:        [NetworkFinding] = []
    @State private var isLoading        = false
    @State private var sufficiencyLabel = ""

    var body: some View {
        HSplitView {
            // ── Left panel: session list ───────────────────────────────────
            SessionListPanel(sessions: sessions,
                             selected: $selectedSession)
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)

            // ── Right panel: findings ──────────────────────────────────────
            FindingsPanel(session:          selectedSession,
                          findings:         findings,
                          isLoading:        isLoading,
                          sufficiencyLabel: sufficiencyLabel)
        }
        .frame(minWidth: 580, minHeight: 400)
        .task {
            await loadSessions()
        }
        .onChange(of: selectedSession?.id) { _ in
            Task { await analyzeSelected() }
        }
    }

    // MARK: - Data loading

    @MainActor
    private func loadSessions() async {
        let db = sqliteStore
        let rows = await Task.detached(priority: .userInitiated) {
            db.sessionsInRange(from: .distantPast, to: .distantFuture)
        }.value
        sessions = rows.sorted { $0.startedAt > $1.startedAt }
        if selectedSession == nil { selectedSession = sessions.first }
    }

    @MainActor
    private func analyzeSelected() async {
        guard let session = selectedSession else {
            findings = []; sufficiencyLabel = ""; return
        }
        isLoading = true
        let db      = sqliteStore
        let sid     = session.id
        let targets = settings.pingTargets
        let analyzer = NetworkAnalyzer(settings: settings)

        let (newFindings, newSufLabel) = await Task.detached(priority: .userInitiated) {
            () -> ([NetworkFinding], String) in
            // External target pings — fetched per-target for divergence analysis,
            // then flattened for single-target patterns.
            var pingsByTarget: [UUID: [SQLiteStore.PingRow]] = [:]
            for t in targets {
                let rows = db.pingRows(for: t.id, sessionID: sid)
                if !rows.isEmpty { pingsByTarget[t.id] = rows }
            }
            let targetPings  = pingsByTarget.values.flatMap { $0 }
                                   .sorted { $0.timestamp < $1.timestamp }
            // Gateway pings kept separate for fault attribution
            let gatewayPings = db.pingRows(for: PingTarget.gatewayID, sessionID: sid)
            let wifiRows     = db.wifiRows(sessionID: sid)
            let speedRows    = db.speedtestRows(from: session.startedAt, to: session.lastSeen)
            let dnsRows            = db.dnsRows(sessionID: sid)
            let dnsResolverRows    = db.dnsResolverRows(sessionID: sid)
            let interfaceErrorRows = db.interfaceErrorRows(sessionID: sid)
            let mtuRows            = db.mtuRows(sessionID: sid)
            let tracerouteRows     = db.tracerouteEvents(sessionID: sid)
            // Cross-session hourly averages: last 30 days of aggregate data
            let hourlyRTTs         = db.hourlyRTTAverages(lookback: 30 * 86_400)

            var input = SessionAnalysisInput(session: session,
                                             pingRows: targetPings,
                                             pingRowsByTarget: pingsByTarget,
                                             gatewayPingRows: gatewayPings,
                                             wifiRows: wifiRows,
                                             speedtestRows: speedRows,
                                             dnsRows: dnsRows,
                                             interfaceErrorRows: interfaceErrorRows,
                                             mtuRows: mtuRows)
            input.dnsResolverRows        = dnsResolverRows
            input.tracerouteRows         = tracerouteRows
            input.crossSessionHourlyRTTs = hourlyRTTs
            let suf = DataSufficiency(sampleCount: targetPings.count)
            let results = analyzer.analyze(input)
            return (results, suf.label)
        }.value

        sufficiencyLabel = newSufLabel
        findings  = newFindings.sorted { $0.confidence > $1.confidence }
        isLoading = false
    }
}

// MARK: - Session list panel

private struct SessionListPanel: View {
    let sessions:  [SQLiteStore.NetworkSessionRow]
    @Binding var selected: SQLiteStore.NetworkSessionRow?

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Networks")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            if sessions.isEmpty {
                Text("No sessions recorded yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                List(sessions, id: \.id, selection: Binding(
                    get: { selected?.id },
                    set: { newID in selected = sessions.first { $0.id == newID } }
                )) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayName)
                            .font(.system(.body, design: .default))
                            .lineLimit(1)
                        Text(Self.dateFmt.string(from: session.startedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(session.id)
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Findings panel

private struct FindingsPanel: View {
    let session:          SQLiteStore.NetworkSessionRow?
    let findings:         [NetworkFinding]
    let isLoading:        Bool
    let sufficiencyLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                if let s = session {
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.displayName)
                            .font(.title2).fontWeight(.semibold)
                        Spacer()
                        if !isLoading && !findings.isEmpty {
                            Text("\(findings.count) issue\(findings.count == 1 ? "" : "s")")
                                .font(.caption).fontWeight(.medium)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 8) {
                        Text(dateRange(s))
                            .font(.caption).foregroundStyle(.secondary)
                        if !sufficiencyLabel.isEmpty {
                            Text("·").foregroundStyle(.secondary)
                            Text(sufficiencyLabel)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Select a network session")
                        .font(.title2).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Content
            if isLoading {
                Spacer()
                ProgressView("Analysing…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if session == nil {
                Spacer()
                Text("Choose a network session on the left to see analysis findings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if findings.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("No issues detected")
                        .font(.headline)
                    Text("All metrics are within normal ranges for this session.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(findings) { finding in
                            FindingCard(finding: finding)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func dateRange(_ s: SQLiteStore.NetworkSessionRow) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return "\(f.string(from: s.startedAt)) — \(f.string(from: s.lastSeen))"
    }
}

// MARK: - Finding card

private struct FindingCard: View {
    let finding: NetworkFinding
    @State private var showingRawOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: categoryIcon)
                    .foregroundStyle(categoryColor)
                    .frame(width: 16)
                Text(finding.title)
                    .font(.headline)
                Spacer()
                ConfidenceBadge(label: finding.confidenceLabel, confidence: finding.confidence)
            }
            Text(finding.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let raw = finding.expandedDetail, !raw.isEmpty {
                DisclosureGroup(isExpanded: $showingRawOutput) {
                    ScrollView(.vertical) {
                        Text(raw)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .frame(maxHeight: 180)
                } label: {
                    Text(showingRawOutput ? "Hide raw output" : "Show raw output")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var categoryIcon: String {
        switch finding.category {
        case .latency:      return "clock"
        case .packetLoss:   return "xmark.circle"
        case .jitter:       return "waveform.path"
        case .wifi:         return "wifi.exclamationmark"
        case .bandwidth:    return "arrow.down.arrow.up"
        case .connectivity: return "network"
        case .dns:          return "globe"
        }
    }

    private var categoryColor: Color {
        switch finding.confidence {
        case 0.80...: return .red
        case 0.55...: return .orange
        default:      return .yellow
        }
    }
}

// MARK: - Confidence badge

private struct ConfidenceBadge: View {
    let label:      String
    let confidence: Double

    var body: some View {
        Text(label)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .cornerRadius(4)
    }

    private var badgeColor: Color {
        switch confidence {
        case 0.80...: return .red
        case 0.55...: return .orange
        default:      return .yellow
        }
    }
}
