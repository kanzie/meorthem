import AppKit
import SwiftUI
import MeOrThemCore

/// Window controller for the Connection Profiles list.
/// Shows per-network ICMP/stealth state, probe port, and lets the user
/// manually toggle stealth mode for a network.
final class ConnectionProfilesWindowController: NSWindowController {

    private let db: SQLiteStore

    init(db: SQLiteStore) {
        self.db = db
        let view = ConnectionProfilesView(db: db)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Connection Profiles"
        window.setContentSize(NSSize(width: 720, height: 480))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 300)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI View

struct ConnectionProfilesView: View {

    let db: SQLiteStore
    /// When set, the row matching this fingerprint is visually highlighted (used
    /// by the Network Intelligence unified window to indicate the active profile).
    var highlightedFingerprint: String? = nil

    @State private var profiles:      [SQLiteStore.ConnectionProfile] = []
    @State private var isLoading      = true
    @State private var editingFP:     String? = nil   // fingerprint of row being label-edited
    @State private var labelDraft:    String  = ""
    @State private var deleteConfirm: String? = nil   // fingerprint pending delete confirm

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading profiles…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if profiles.isEmpty {
                Text("No connection profiles recorded yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(profiles) { p in
                        profileRow(p)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task { await load() }
        .alert("Delete profile?", isPresented: Binding(
            get: { deleteConfirm != nil },
            set: { if !$0 { deleteConfirm = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let fp = deleteConfirm {
                    db.deleteConnectionProfile(fingerprint: fp)
                    profiles.removeAll { $0.fingerprint == fp }
                }
                deleteConfirm = nil
            }
            Button("Cancel", role: .cancel) { deleteConfirm = nil }
        } message: {
            Text("This removes all stored settings for this network. Monitoring data is kept.")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func profileRow(_ p: SQLiteStore.ConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {

                // — Identity column
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // User label takes precedence; falls back to auto displayName
                        if let label = p.userLabel, !label.isEmpty {
                            Text(label)
                                .font(.system(.body, weight: .medium))
                                .lineLimit(1)
                            Text("(\(p.displayName))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(p.displayName)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                        if p.fingerprint == highlightedFingerprint {
                            Text("Active")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.green))
                        }
                    }

                    // Inline label editor
                    if editingFP == p.fingerprint {
                        HStack(spacing: 6) {
                            TextField("Label (e.g. Home, Office)", text: $labelDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .frame(maxWidth: 200)
                                .onSubmit { commitLabel(for: p) }
                            Button("Save") { commitLabel(for: p) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.mini)
                            Button("Cancel") { editingFP = nil }
                                .buttonStyle(.plain)
                                .controlSize(.mini)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 3)
                    } else {
                        Button {
                            labelDraft = p.userLabel ?? ""
                            editingFP  = p.fingerprint
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "tag")
                                    .imageScale(.small)
                                Text(p.userLabel.map { $0.isEmpty ? "Add label…" : "Edit label" } ?? "Add label…")
                            }
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 12)

                // — Type badge
                stealthBadge(p)
                    .frame(width: 90, alignment: .center)

                // — ICMP status
                icmpStatus(p)
                    .frame(width: 90, alignment: .leading)

                // — Session count
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(p.totalSessions)")
                        .monospacedDigit()
                        .font(.callout)
                    Text("sessions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 55, alignment: .trailing)

                // — Last seen
                VStack(alignment: .trailing, spacing: 1) {
                    Text(p.lastSeen.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                    Text(p.lastSeen.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 90, alignment: .trailing)

                // — Delete
                Button {
                    deleteConfirm = p.fingerprint
                } label: {
                    Image(systemName: "trash")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this profile")
            }
            .padding(.vertical, 6)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
    }

    // MARK: - Helpers

    private func commitLabel(for p: SQLiteStore.ConnectionProfile) {
        let trimmed  = labelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLabel: String? = trimmed.isEmpty ? nil : trimmed
        db.setConnectionProfileLabel(fingerprint: p.fingerprint, label: newLabel)
        editingFP = nil
        // Reload from DB so the list reflects the saved label without
        // needing a public memberwise initializer on ConnectionProfile.
        Task { await load() }
    }

    @ViewBuilder
    private func stealthBadge(_ p: SQLiteStore.ConnectionProfile) -> some View {
        if p.stealthMode {
            Text("Stealth (RAW)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.purple))
        } else {
            Text("ICMP (Ping)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
        }
    }

    @ViewBuilder
    private func icmpStatus(_ p: SQLiteStore.ConnectionProfile) -> some View {
        if p.icmpThrottled {
            Label("Blocked", systemImage: "nosign")
                .font(.caption)
                .foregroundStyle(.red)
        } else if let lastOk = p.icmpLastOkAt {
            VStack(alignment: .leading, spacing: 1) {
                Label("OK", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(lastOk.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        let rows = await Task.detached { [db] in db.allConnectionProfiles() }.value
        profiles = rows
        isLoading = false
    }
}
