import AppKit
import SwiftUI
import MeOrThemCore

final class PingReportWindowController: NSWindowController {

    private let sqliteStore: SQLiteStore
    private let settings:    AppSettings
    private let exporter:    ExportCoordinator
    var onShowCharts: (() -> Void)?

    init(sqliteStore: SQLiteStore, settings: AppSettings, exporter: ExportCoordinator,
         onShowCharts: (() -> Void)? = nil) {
        self.sqliteStore  = sqliteStore
        self.settings     = settings
        self.exporter     = exporter
        self.onShowCharts = onShowCharts

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Export Report"
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showAndFocus() {
        let view = PingReportView(
            sqliteStore:  sqliteStore,
            settings:     settings,
            exporter:     exporter,
            onShowCharts: onShowCharts
        )
        window?.contentViewController = NSHostingController(rootView: view)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - View

private struct PingReportView: View {
    let sqliteStore:  SQLiteStore
    let settings:     AppSettings
    let exporter:     ExportCoordinator
    var onShowCharts: (() -> Void)?

    @State private var startDate = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var endDate   = Date()
    @State private var reportText: String = "Generating report…"
    @State private var copied = false

    private var dateRangeKey: String {
        "\(Int(startDate.timeIntervalSince1970))-\(Int(endDate.timeIntervalSince1970))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Date range row ─────────────────────────────────────────────
            HStack(spacing: 10) {
                Text("From").fontWeight(.medium)
                DatePicker("", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Text("To").fontWeight(.medium)
                DatePicker("", selection: $endDate, in: startDate..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Spacer()
            }

            // ── Preview ────────────────────────────────────────────────────
            ScrollView {
                Text(reportText)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            // ── Action buttons ─────────────────────────────────────────────
            HStack(spacing: 8) {
                Button("Export CSV")  { exporter.exportCSV(from: startDate, to: endDate) }
                Button("Export PDF")  { exporter.exportPDF(from: startDate, to: endDate) }
                Button("Export JSON") { exporter.exportJSON(from: startDate, to: endDate) }
                if let showCharts = onShowCharts {
                    Button("View Charts") { showCharts() }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
                Button(copied ? "Copied!" : "Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reportText, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 740, minHeight: 420)
        .task(id: dateRangeKey) {
            await refreshReport()
        }
    }

    // MARK: - Report generation

    @MainActor
    private func refreshReport() async {
        let from    = startDate
        let to      = endDate
        let targets = settings.pingTargets
        let db      = sqliteStore
        reportText = await Task.detached(priority: .userInitiated) {
            buildPingReportText(db: db, targets: targets, from: from, to: to)
        }.value
    }

    // See free function buildPingReportText below for report generation logic.
}

// MARK: - Report text builder (free function, nonisolated, safe for Task.detached)

// Row limits for the live preview. Keeps the window snappy on large datasets.
private let previewMaxPingRowsPerTarget = 50
private let previewMaxWifiRows          = 30

private let _reportDateFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateStyle = .medium
    fmt.timeStyle = .short
    return fmt
}()

private func buildPingReportText(db: SQLiteStore, targets: [PingTarget],
                                  from: Date, to: Date) -> String {
    let fmt = _reportDateFormatter

    var lines: [String] = []
    var truncatedRows = 0   // total rows hidden across all sections

    lines.append("Me Or Them Network Report")
    lines.append("Period: \(fmt.string(from: from)) — \(fmt.string(from: to))")
    lines.append(String(repeating: "─", count: 60))
    lines.append("")

    // ── Ping targets ───────────────────────────────────────────────────
    lines.append("PING TARGETS")
    for target in targets {
        lines.append("  \(target.label) (\(target.host)):")
        let rows = db.pingRows(for: target.id, from: from, to: to)
        if rows.isEmpty {
            lines.append("    No data in this period")
        } else {
            let rtts    = rows.compactMap(\.rttMs)
            let avgRtt  = rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count)
            let maxRtt  = rtts.max() ?? 0
            let avgLoss = rows.map(\.lossPct).reduce(0, +) / Double(rows.count)
            let jitters = rows.compactMap(\.jitterMs)
            let avgJit  = jitters.isEmpty ? 0 : jitters.reduce(0, +) / Double(jitters.count)
            lines.append("    Samples:    \(rows.count)")
            lines.append("    Avg RTT:    \(String(format: "%.1f ms", avgRtt))")
            lines.append("    Max RTT:    \(String(format: "%.1f ms", maxRtt))")
            lines.append("    Avg Loss:   \(String(format: "%.1f%%", avgLoss))")
            lines.append("    Avg Jitter: \(String(format: "%.1f ms", avgJit))")

            // Show most-recent rows, capped for preview performance
            let cap     = previewMaxPingRowsPerTarget
            let visible = rows.suffix(cap)
            let hidden  = rows.count - visible.count
            if hidden > 0 {
                truncatedRows += hidden
                lines.append("    (\(hidden) older rows not shown in preview)")
            }
            lines.append("    Recent samples:")
            for r in visible {
                let ts  = fmt.string(from: r.timestamp)
                let rtt = r.rttMs.map { String(format: "%.1f ms", $0) } ?? "timeout"
                let los = String(format: "%.1f%%", r.lossPct)
                lines.append("      [\(ts)]  \(rtt)  loss \(los)")
            }
        }
    }

    // ── Bandwidth tests ────────────────────────────────────────────────
    lines.append("")
    lines.append("BANDWIDTH TESTS")
    let speedRows = db.speedtestRows(from: from, to: to)
    if speedRows.isEmpty {
        lines.append("  No bandwidth tests in this period")
    } else {
        for s in speedRows {
            lines.append("  [\(fmt.string(from: s.timestamp))]")
            let dl  = String(format: "%.1f Mbps", s.downloadMbps)
            let ul  = String(format: "%.1f Mbps", s.uploadMbps)
            let lat = String(format: "%.1f ms",   s.latencyMs)
            let jit = String(format: "%.1f ms",   s.jitterMs)
            lines.append("    ↓ \(dl)  ↑ \(ul)  Latency \(lat)  Jitter ±\(jit)")
            if !s.isp.isEmpty && s.isp != "Unknown" {
                lines.append("    ISP: \(s.isp)  |  Server: \(s.serverName)")
            }
        }
    }

    // ── Wi-Fi history ──────────────────────────────────────────────────
    lines.append("")
    lines.append("WI-FI HISTORY")
    let wifiRows = db.wifiRows(from: from, to: to)
    if wifiRows.isEmpty {
        lines.append("  No Wi-Fi data in this period")
    } else {
        let cap         = previewMaxWifiRows
        let visibleWifi = wifiRows.suffix(cap)
        let hiddenWifi  = wifiRows.count - visibleWifi.count
        if hiddenWifi > 0 {
            truncatedRows += hiddenWifi
            lines.append("  (\(hiddenWifi) older Wi-Fi samples not shown in preview)")
        }
        for w in visibleWifi {
            let ghz = String(format: "%.1f", w.bandGHz)
            let tx  = String(format: "%.0f", w.txRateMbps)
            lines.append("  [\(fmt.string(from: w.timestamp))]  RSSI \(w.rssi) dBm  SNR \(w.snr) dB  Ch \(w.channelNumber) (\(ghz) GHz)  TX \(tx) Mbps")
        }
    }

    // ── Truncation notice ──────────────────────────────────────────────
    if truncatedRows > 0 {
        lines.append("")
        lines.append(String(repeating: "─", count: 60))
        lines.append("⚠ Preview truncated: \(truncatedRows) rows hidden for performance.")
        lines.append("  Use the export buttons above to get the complete dataset.")
    }

    return lines.joined(separator: "\n")
}
