import SwiftUI
import MeOrThemCore   // for InputValidator (Bug 15: removed duplicate from MeOrThem/Utilities)

struct TargetsTab: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var newLabel     = ""
    @State private var newHost      = ""
    @State private var newProbeMode: ProbeMode = .icmp
    @State private var editingIndex: Int?
    @State private var errorMsg: String?
    @State private var gatewayIP: String = "—"

    // Threshold override editing state
    @State private var overrideEnabled:     Bool       = false
    @State private var editingThresholds:   Thresholds = .default
    @State private var showThresholdGroup:  Bool       = false

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
                        targetRow(target: target, index: index)
                    }
                    .onDelete(perform: delete)
                }
            }
            .listStyle(.bordered)
            .frame(maxHeight: .infinity)

            Divider()

            // Add / Edit row
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Label", text: $newLabel)
                        .frame(width: 100)
                        .textFieldStyle(.roundedBorder)
                    TextField("IP or hostname", text: $newHost)
                        .frame(maxWidth: .infinity)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commit)
                    Picker("", selection: $newProbeMode) {
                        ForEach(ProbeMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .frame(width: 80)
                    .labelsHidden()

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

                // Per-target threshold override (only shown while editing)
                if isEditing {
                    DisclosureGroup("Custom Thresholds", isExpanded: $showThresholdGroup) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Override global thresholds", isOn: $overrideEnabled)
                                .toggleStyle(.checkbox)

                            if overrideEnabled {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                    GridRow {
                                        Text("").gridCellColumns(1)
                                        Text("Yellow").font(.caption).foregroundStyle(.orange).gridCellColumns(1)
                                        Text("Red").font(.caption).foregroundStyle(.red).gridCellColumns(1)
                                    }
                                    thresholdGridRow("Latency",
                                                     yellow: $editingThresholds.latencyYellowMs,
                                                     red:    $editingThresholds.latencyRedMs,
                                                     unit: "ms")
                                    thresholdGridRow("Loss",
                                                     yellow: $editingThresholds.lossYellowPct,
                                                     red:    $editingThresholds.lossRedPct,
                                                     unit: "%")
                                    thresholdGridRow("Jitter",
                                                     yellow: $editingThresholds.jitterYellowMs,
                                                     red:    $editingThresholds.jitterRedMs,
                                                     unit: "ms")
                                }
                                .padding(.leading, 4)

                                Button("Reset to Defaults") {
                                    editingThresholds = .default
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
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

    // MARK: - Target list row

    @ViewBuilder
    private func targetRow(target: PingTarget, index: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.label)
                    .font(.system(.body, design: .monospaced))
                Text(target.host)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if target.probeMode != .icmp {
                Text(target.probeMode.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
            }
            if target.thresholdOverride != nil {
                customBadge
            }
            if editingIndex == index {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { selectForEditing(index: index) }
    }

    private var customBadge: some View {
        Text("custom")
            .font(.caption2)
            .foregroundStyle(Color(nsColor: .controlAccentColor))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .controlAccentColor).opacity(0.12)))
    }

    // MARK: - Threshold grid row helper

    @ViewBuilder
    private func thresholdGridRow(_ label: String,
                                  yellow: Binding<Double>,
                                  red:    Binding<Double>,
                                  unit: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                TextField("", value: yellow, format: .number)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                TextField("", value: red, format: .number)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Text(unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func selectForEditing(index: Int) {
        let target = settings.pingTargets[index]
        newLabel              = target.label
        newHost               = target.host
        newProbeMode          = target.probeMode
        editingIndex          = index
        errorMsg              = nil
        overrideEnabled       = target.thresholdOverride != nil
        editingThresholds     = target.thresholdOverride ?? .default
        showThresholdGroup    = target.thresholdOverride != nil
    }

    private func deleteEditing() {
        guard let idx = editingIndex else { return }
        delete(at: IndexSet(integer: idx))
    }

    private func cancelEditing() {
        editingIndex       = nil
        newLabel           = ""
        newHost            = ""
        newProbeMode       = .icmp
        errorMsg           = nil
        overrideEnabled    = false
        editingThresholds  = .default
        showThresholdGroup = false
    }

    private func commit() {
        let host  = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty, !label.isEmpty else { return }

        guard InputValidator.isValidPingTarget(host) else {
            errorMsg = "Invalid hostname or IP address."
            return
        }

        let override: Thresholds? = overrideEnabled ? editingThresholds : nil

        if let idx = editingIndex {
            let duplicate = settings.pingTargets.indices.contains(where: {
                $0 != idx && settings.pingTargets[$0].host.lowercased() == host.lowercased()
            })
            if duplicate {
                errorMsg = "A target with that host already exists."
                return
            }
            settings.pingTargets[idx] = PingTarget(
                id:                settings.pingTargets[idx].id,
                label:             InputValidator.sanitizedLabel(label),
                host:              host,
                probeMode:         newProbeMode,
                thresholdOverride: override
            )
            cancelEditing()
        } else {
            guard settings.pingTargets.count < 10 else {
                errorMsg = "Maximum 10 targets allowed."
                return
            }
            let duplicate = settings.pingTargets.contains(where: {
                $0.host.lowercased() == host.lowercased()
            })
            if duplicate {
                errorMsg = "A target with that host already exists."
                return
            }
            settings.pingTargets.append(
                PingTarget(label: InputValidator.sanitizedLabel(label), host: host,
                           probeMode: newProbeMode)
            )
            newLabel     = ""
            newHost      = ""
            newProbeMode = .icmp
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
