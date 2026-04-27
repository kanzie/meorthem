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
        window.setContentSize(NSSize(width: 680, height: 460))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 500, height: 300)
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

    @State private var profiles: [SQLiteStore.ConnectionProfile] = []
    @State private var isLoading = true

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
                Table(profiles) {
                    TableColumn("Network") { p in
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.displayName)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                Text(p.fingerprint)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
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
                        .padding(.vertical, 2)
                    }
                    .width(min: 140, ideal: 220)

                    TableColumn("Type") { p in
                        stealthBadge(p)
                    }
                    .width(90)

                    TableColumn("ICMP Status") { p in
                        icmpStatus(p)
                    }
                    .width(100)

                    TableColumn("Sessions") { p in
                        Text("\(p.totalSessions)")
                            .monospacedDigit()
                    }
                    .width(60)

                    TableColumn("Last Seen") { p in
                        Text(p.lastSeen.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 160)
                }
                .alternatingRowBackgrounds()
            }
        }
        .task { await load() }
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
