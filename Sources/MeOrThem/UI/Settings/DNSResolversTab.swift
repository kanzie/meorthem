import SwiftUI
import MeOrThemCore

// MARK: - DNS Resolvers settings tab

struct DNSResolversTab: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var newName = ""
    @State private var newIP   = ""
    @State private var errorMsg: String?

    // Maximum number of simultaneously enabled resolvers.
    private let maxEnabled = 8

    private var enabledCount: Int {
        settings.dnsResolvers.filter { $0.isEnabled }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            List {
                // ── Pre-populated resolvers ──────────────────────────────
                Section(header: Text("Resolvers").font(.caption).foregroundStyle(.secondary)) {
                    ForEach(settings.dnsResolvers) { resolver in
                        ResolverRow(resolver: resolver,
                                    canEnable: enabledCount < maxEnabled || resolver.isEnabled,
                                    onToggle: { toggle(resolver) },
                                    onReset: { resetFailures(resolver) })
                    }
                    .onDelete(perform: deleteResolvers)
                }
            }
            .listStyle(.bordered)
            .frame(maxHeight: .infinity)

            Divider()

            // ── Add custom resolver ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Name (optional)", text: $newName)
                        .frame(width: 140)
                        .textFieldStyle(.roundedBorder)

                    TextField("IP address", text: $newIP)
                        .frame(maxWidth: .infinity)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)

                    Button("Add", action: commit)
                        .disabled(newIP.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let err = errorMsg {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Text("Max \(maxEnabled) enabled at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") { resetToDefaults() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Actions

    private func toggle(_ resolver: DNSResolver) {
        guard let idx = settings.dnsResolvers.firstIndex(where: { $0.id == resolver.id }) else { return }
        let current = settings.dnsResolvers[idx].isEnabled
        if !current && enabledCount >= maxEnabled { return }  // cap
        settings.dnsResolvers[idx].isEnabled = !current
    }

    private func resetFailures(_ resolver: DNSResolver) {
        settings.reEnableDNSResolver(id: resolver.id)
    }

    private func deleteResolvers(at offsets: IndexSet) {
        // Only user-added resolvers can be deleted (not pre-populated ones).
        // Pre-populated resolvers have no isSystem/isGateway + are in the defaults list.
        let defaultIPs = Set(DNSResolver.defaults.map { $0.ip })
        var toRemove = IndexSet()
        for i in offsets {
            let r = settings.dnsResolvers[i]
            let isDefault = defaultIPs.contains(r.ip) || r.isSystem || r.isGateway
            if !isDefault { toRemove.insert(i) }
        }
        settings.dnsResolvers.remove(atOffsets: toRemove)
    }

    private func commit() {
        let ip = newIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }

        // Validate using inet_pton (IPv4 or IPv6)
        guard InputValidator.isValidIP(ip) else {
            errorMsg = "Enter a valid IPv4 or IPv6 address (not a hostname or URL)."
            return
        }
        // No duplicates
        if settings.dnsResolvers.contains(where: { $0.ip == ip }) {
            errorMsg = "This IP is already in the list."
            return
        }
        let name = newName.trimmingCharacters(in: .whitespaces).isEmpty
                 ? ip : newName.trimmingCharacters(in: .whitespaces)
        let newResolver = DNSResolver(name: name, ip: ip,
                                      isEnabled: enabledCount < maxEnabled)
        settings.dnsResolvers.append(newResolver)
        newName = ""; newIP = ""; errorMsg = nil
    }

    private func resetToDefaults() {
        settings.dnsResolvers = DNSResolver.defaults
    }
}

// MARK: - Resolver row

private struct ResolverRow: View {
    let resolver: DNSResolver
    let canEnable: Bool
    let onToggle: () -> Void
    let onReset: () -> Void

    private var statusBadge: (label: String, color: Color)? {
        if let _ = resolver.autoDisabledAt {
            return ("Auto-paused", .orange)
        }
        if resolver.isEnabled { return ("Active", .green) }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { resolver.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .disabled(!canEnable && !resolver.isEnabled)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(resolver.name)
                        .font(.system(.body, design: .default))
                        .lineLimit(1)

                    if let badge = statusBadge {
                        Text(badge.label)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(badge.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(badge.color.opacity(0.12))
                            .cornerRadius(3)
                    }

                    if resolver.autoDisabledAt != nil {
                        Button("Re-enable") { onReset() }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }

                if resolver.isSystem {
                    Text("Dynamic — reads /etc/resolv.conf at probe time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if resolver.isGateway {
                    Text("Dynamic — uses current default gateway IP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let suffix = resolver.ip.contains(":") ? " (IPv6)" : ""
                    Text(resolver.ip + suffix)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
