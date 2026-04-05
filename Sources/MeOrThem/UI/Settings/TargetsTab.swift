import SwiftUI
import MeOrThemCore   // for InputValidator (Bug 15: removed duplicate from MeOrThem/Utilities)

struct TargetsTab: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var newLabel    = ""
    @State private var newHost     = ""
    @State private var editingIndex: Int?
    @State private var errorMsg: String?
    @State private var gatewayIP: String = "—"

    private var isEditing: Bool { editingIndex != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                // System targets section (non-removable)
                Section(header: Text("System").font(.caption).foregroundStyle(.secondary)) {
                    HStack {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Gateway")
                                .font(.system(.body, design: .monospaced))
                            Text(gatewayIP)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .opacity(0.8)
                }

                // User targets section
                Section(header: Text("Targets").font(.caption).foregroundStyle(.secondary)) {
                    ForEach(Array(settings.pingTargets.enumerated()), id: \.element.id) { index, target in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.label)
                                    .font(.system(.body, design: .monospaced))
                                Text(target.host)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if editingIndex == index {
                                Image(systemName: "pencil.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .onTapGesture { selectForEditing(index: index) }
                    }
                    .onDelete(perform: delete)
                }
            }
            .listStyle(.bordered)
            .frame(maxHeight: .infinity)

            Divider()

            // Add / Edit row
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Label", text: $newLabel)
                        .frame(width: 120)
                        .textFieldStyle(.roundedBorder)
                    TextField("IP or hostname", text: $newHost)
                        .frame(maxWidth: .infinity)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)

                    if isEditing {
                        Button(role: .destructive) { deleteEditing() } label: {
                            Text("Delete").foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }

                    Button(isEditing ? "Update" : "Add", action: commit)
                        .disabled(newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  newHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if isEditing {
                        Button("Cancel") { cancelEditing() }
                            .buttonStyle(.borderless)
                    }
                }

                if let err = errorMsg {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(12)
        }
        .onAppear {
            gatewayIP = NetworkInfo.defaultGateway() ?? "—"
        }
    }

    // MARK: - Actions

    private func selectForEditing(index: Int) {
        let target = settings.pingTargets[index]
        newLabel     = target.label
        newHost      = target.host
        editingIndex = index
        errorMsg     = nil
    }

    private func deleteEditing() {
        guard let idx = editingIndex else { return }
        delete(at: IndexSet(integer: idx))
    }

    private func cancelEditing() {
        editingIndex = nil
        newLabel     = ""
        newHost      = ""
        errorMsg     = nil
    }

    private func commit() {
        let host  = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty, !label.isEmpty else { return }

        guard InputValidator.isValidPingTarget(host) else {
            errorMsg = "Invalid hostname or IP address."
            return
        }

        if let idx = editingIndex {
            settings.pingTargets[idx] = PingTarget(
                id: settings.pingTargets[idx].id,
                label: InputValidator.sanitizedLabel(label),
                host: host
            )
            cancelEditing()
        } else {
            guard settings.pingTargets.count < 10 else {
                errorMsg = "Maximum 10 targets allowed."
                return
            }
            settings.pingTargets.append(
                PingTarget(label: InputValidator.sanitizedLabel(label), host: host)
            )
            newLabel = ""
            newHost  = ""
        }
        errorMsg = nil
    }

    private func delete(at offsets: IndexSet) {
        if let idx = editingIndex, offsets.contains(idx) { cancelEditing() }

        guard settings.pingTargets.count - offsets.count >= 1 else {
            errorMsg = "Keep at least one target."
            return
        }
        settings.pingTargets.remove(atOffsets: offsets)

        if let idx = editingIndex {
            let deletedBelow = offsets.filter { $0 < idx }.count
            editingIndex = idx - deletedBelow
        }
        errorMsg = nil
    }
}
