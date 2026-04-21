import SwiftUI
@preconcurrency import MeOrThemCore

struct IncidentHistoryView: View {
    let sqliteStore: SQLiteStore
    var onShowCharts: ((Date, Date) -> Void)?

    @State private var rows: [SQLiteStore.IncidentRow] = []
    @State private var isLoading = true
    @State private var filterFrom: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var filterTo:   Date = Date()
    @State private var isFiltering = false
    @State private var showClearConfirm = false

    private static let startFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                DatePicker("From", selection: $filterFrom, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Text("–")
                    .foregroundStyle(.secondary)
                DatePicker("To", selection: $filterTo, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()

                Button("Filter") { applyFilter() }
                    .buttonStyle(.bordered)

                Button("Clear Filter") { loadAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear All…") { showClearConfirm = true }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading incidents…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No incidents recorded")
                            .foregroundStyle(.secondary)
                        Text("Incidents are logged when your connection degrades.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(rows) { inc in
                        incidentRow(inc)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if !rows.isEmpty {
                    Text("\(rows.count) incident\(rows.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { NSApplication.shared.keyWindow?.performClose(nil) }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 400)
        .task { loadAll() }
        .alert("Clear all incident history?", isPresented: $showClearConfirm) {
            Button("Clear All", role: .destructive) { clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all recorded incidents. This action cannot be undone.")
        }
    }

    // MARK: - Row view

    @ViewBuilder
    private func incidentRow(_ inc: SQLiteStore.IncidentRow) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(inc.peakSeverityRaw >= 2 ? Color.red : Color.orange)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(Self.startFmt.string(from: inc.startedAt))
                        .font(.system(.body, design: .monospaced))
                    if inc.isActive {
                        Text("ACTIVE")
                            .font(.caption2)
                            .bold()
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.15)))
                    }
                }
                Text(inc.cause.count > 60 ? String(inc.cause.prefix(60)) + "…" : inc.cause)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(duration(of: inc))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)

            if let onShowCharts {
                Button("View") {
                    let start = inc.startedAt.addingTimeInterval(-300)
                    let end   = (inc.endedAt ?? Date()).addingTimeInterval(300)
                    onShowCharts(start, end)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func duration(of inc: SQLiteStore.IncidentRow) -> String {
        guard let end = inc.endedAt else { return "ongoing" }
        let secs = Int(end.timeIntervalSince(inc.startedAt))
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        let rem  = secs % 60
        return rem > 0 ? "\(mins)m \(rem)s" : "\(mins)m"
    }

    private func loadAll() {
        isFiltering = false
        isLoading   = true
        let db = sqliteStore
        Task.detached(priority: .userInitiated) {
            let result = db.allIncidentRows(limit: 500)
            await MainActor.run {
                rows      = result
                isLoading = false
            }
        }
    }

    private func applyFilter() {
        isFiltering = true
        isLoading   = true
        let db   = sqliteStore
        let from = filterFrom
        let to   = filterTo
        Task.detached(priority: .userInitiated) {
            let result = db.incidentRows(from: from, to: to, limit: 500)
            await MainActor.run {
                rows      = result
                isLoading = false
            }
        }
    }

    private func clearAll() {
        sqliteStore.clearAllIncidents()
        rows = []
    }
}
