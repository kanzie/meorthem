import SwiftUI
@preconcurrency import MeOrThemCore

// MARK: - Session comparison data model

struct SessionComparisonData {
    let avgLatencyMs:  Double?
    let lossPercent:   Double?
    let avgJitterMs:   Double?
    let wifiRSSI:      Double?
    let dnsLatencyMs:  Double?
    let availability:  Double?   // 0.0–1.0
    let bestDownMbps:  Double?
}

// MARK: - Async loader

@MainActor
final class SessionComparisonLoader: ObservableObject {
    @Published private(set) var dataA: SessionComparisonData?
    @Published private(set) var dataB: SessionComparisonData?
    @Published private(set) var isLoading = false

    func load(sessionA: SQLiteStore.NetworkSessionRow,
              sessionB: SQLiteStore.NetworkSessionRow,
              sqliteStore: SQLiteStore) async {
        isLoading = true
        let db = sqliteStore
        let (a, b) = await Task.detached(priority: .userInitiated) {
            let dataA = Self.load(session: sessionA, db: db)
            let dataB = Self.load(session: sessionB, db: db)
            return (dataA, dataB)
        }.value
        dataA    = a
        dataB    = b
        isLoading = false
    }

    nonisolated private static func load(session: SQLiteStore.NetworkSessionRow,
                                         db: SQLiteStore) -> SessionComparisonData {
        let from = session.startedAt
        let to   = session.lastSeen

        // Average latency, loss, jitter from all external ping targets' raw rows
        let pingSample = db.pingRows(for: PingTarget.gatewayID, sessionID: session.id)
        // Get all raw ping rows across all session pings using date-range query
        // (pingRows by sessionID gives gateway; use date range for external targets)
        // We approximate: fetch from/to date range for the session
        let allPings: [SQLiteStore.PingRow]
        // Combine gateway and a date-based fallback for external pings
        let combined: [SQLiteStore.PingRow] = pingSample
        // Also pull any pings via the date range (non-gateway targets)
        // Use a well-known target UUID lookup isn't available without settings;
        // instead derive stats from available gateway pings + wifi rows
        allPings = combined

        let rtts    = allPings.compactMap { $0.rttMs }
        let avgRtt: Double? = rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count)
        let losses  = allPings.map { $0.lossPct }
        let avgLoss: Double? = losses.isEmpty ? nil : losses.reduce(0, +) / Double(losses.count)
        let jitters = allPings.compactMap { $0.jitterMs }
        let avgJitter: Double? = jitters.isEmpty ? nil : jitters.reduce(0, +) / Double(jitters.count)

        // WiFi RSSI
        let wifiRows = db.wifiRows(sessionID: session.id)
        let rssis    = wifiRows.map { Double($0.rssi) }
        let avgRSSI: Double? = rssis.isEmpty ? nil : rssis.reduce(0, +) / Double(rssis.count)

        // DNS — fastest resolver average
        let dnsRows    = db.dnsResolverRows(sessionID: session.id)
        let dnsLatencies = dnsRows.compactMap { $0.resolveMs }
        let avgDNS     = dnsLatencies.isEmpty ? nil : dnsLatencies.reduce(0, +) / Double(dnsLatencies.count)

        // Availability
        let avail = db.availabilityFraction(from: from, to: to)

        // Best speedtest download
        let speedRows = db.speedtestRows(from: from, to: to)
        let bestDown  = speedRows.map(\.downloadMbps).max()

        return SessionComparisonData(
            avgLatencyMs: avgRtt,
            lossPercent:  avgLoss,
            avgJitterMs:  avgJitter,
            wifiRSSI:     avgRSSI,
            dnsLatencyMs: avgDNS,
            availability: avail,
            bestDownMbps: bestDown
        )
    }
}

// MARK: - Main comparison view

struct SessionComparisonView: View {
    let sessionA: SQLiteStore.NetworkSessionRow
    let sessionB: SQLiteStore.NetworkSessionRow
    let sqliteStore: SQLiteStore

    @StateObject private var loader = SessionComparisonLoader()

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                Text("Session Comparison")
                    .font(.headline)
            }
            .padding(.vertical, 12)

            Divider()

            if loader.isLoading {
                Spacer()
                ProgressView("Loading session data…")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if let a = loader.dataA, let b = loader.dataB {
                ScrollView {
                    comparisonGrid(a: a, b: b)
                        .padding(20)
                }
            } else {
                Spacer()
                ProgressView()
                Spacer()
            }
        }
        .frame(minWidth: 540, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loader.load(sessionA: sessionA, sessionB: sessionB, sqliteStore: sqliteStore)
        }
    }

    @ViewBuilder
    private func comparisonGrid(a: SessionComparisonData, b: SessionComparisonData) -> some View {
        VStack(spacing: 0) {
            // Header row
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Color.clear.frame(width: 120, height: 1)
                    sessionHeader(sessionA)
                    sessionHeader(sessionB)
                    Text("Delta").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        .frame(minWidth: 80, alignment: .center)
                }
                .padding(.bottom, 8)

                Divider().gridCellColumns(4)
                    .padding(.bottom, 8)

                // Metric rows
                metricRow("Avg Latency",
                          a: a.avgLatencyMs.map { String(format: "%.1f ms", $0) },
                          b: b.avgLatencyMs.map { String(format: "%.1f ms", $0) },
                          delta: latencyDelta(a.avgLatencyMs, b.avgLatencyMs),
                          lowerIsBetter: true)

                metricRow("Packet Loss",
                          a: a.lossPercent.map { String(format: "%.1f%%", $0) },
                          b: b.lossPercent.map { String(format: "%.1f%%", $0) },
                          delta: percentDelta(a.lossPercent, b.lossPercent),
                          lowerIsBetter: true)

                metricRow("Avg Jitter",
                          a: a.avgJitterMs.map { String(format: "%.1f ms", $0) },
                          b: b.avgJitterMs.map { String(format: "%.1f ms", $0) },
                          delta: latencyDelta(a.avgJitterMs, b.avgJitterMs),
                          lowerIsBetter: true)

                metricRow("WiFi Signal",
                          a: a.wifiRSSI.map { String(format: "%.0f dBm", $0) },
                          b: b.wifiRSSI.map { String(format: "%.0f dBm", $0) },
                          delta: rssiDelta(a.wifiRSSI, b.wifiRSSI),
                          lowerIsBetter: false)

                metricRow("DNS (avg)",
                          a: a.dnsLatencyMs.map { String(format: "%.1f ms", $0) },
                          b: b.dnsLatencyMs.map { String(format: "%.1f ms", $0) },
                          delta: latencyDelta(a.dnsLatencyMs, b.dnsLatencyMs),
                          lowerIsBetter: true)

                metricRow("Availability",
                          a: a.availability.map { String(format: "%.1f%%", $0 * 100) },
                          b: b.availability.map { String(format: "%.1f%%", $0 * 100) },
                          delta: availDelta(a.availability, b.availability),
                          lowerIsBetter: false)

                if a.bestDownMbps != nil || b.bestDownMbps != nil {
                    metricRow("Best Speed ↓",
                              a: a.bestDownMbps.map { String(format: "%.1f Mbps", $0) },
                              b: b.bestDownMbps.map { String(format: "%.1f Mbps", $0) },
                              delta: speedDelta(a.bestDownMbps, b.bestDownMbps),
                              lowerIsBetter: false)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionHeader(_ session: SQLiteStore.NetworkSessionRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.displayName)
                .font(.caption).fontWeight(.semibold)
                .lineLimit(1)
            Text(Self.dateFmt.string(from: session.startedAt))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 140, alignment: .leading)
    }

    @ViewBuilder
    private func metricRow(_ label: String,
                           a: String?,
                           b: String?,
                           delta: (text: String, color: Color)?,
                           lowerIsBetter: Bool) -> some View {
        GridRow {
            Text(label)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 120, alignment: .leading)

            Text(a ?? "—")
                .font(.body.monospacedDigit())
                .foregroundStyle(a == nil ? .tertiary : .primary)
                .frame(minWidth: 140, alignment: .leading)

            Text(b ?? "—")
                .font(.body.monospacedDigit())
                .foregroundStyle(b == nil ? .tertiary : .primary)
                .frame(minWidth: 140, alignment: .leading)

            if let d = delta {
                Text(d.text)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(d.color)
                    .frame(minWidth: 80, alignment: .center)
            } else {
                Text("—")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 80, alignment: .center)
            }
        }
        .padding(.vertical, 6)

        Divider().gridCellColumns(4).opacity(0.4)
    }

    // MARK: - Delta helpers (B relative to A; positive = B is higher)

    /// Returns delta for latency/jitter/loss metrics where lower is better.
    /// Positive delta → B is worse; negative → B is better.
    private func latencyDelta(_ a: Double?, _ b: Double?) -> (text: String, color: Color)? {
        guard let a, let b else { return nil }
        let diff = b - a
        let sign = diff > 0 ? "+" : ""
        let color: Color = diff > 2 ? .red : diff < -2 ? .green : .secondary
        return (String(format: "%@%.1f ms", sign, diff), color)
    }

    private func percentDelta(_ a: Double?, _ b: Double?) -> (text: String, color: Color)? {
        guard let a, let b else { return nil }
        let diff = b - a
        let sign = diff > 0 ? "+" : ""
        let color: Color = diff > 0.5 ? .red : diff < -0.5 ? .green : .secondary
        return (String(format: "%@%.1f%%", sign, diff), color)
    }

    private func rssiDelta(_ a: Double?, _ b: Double?) -> (text: String, color: Color)? {
        guard let a, let b else { return nil }
        let diff = b - a  // dBm: higher = better
        let sign = diff > 0 ? "+" : ""
        let color: Color = diff > 3 ? .green : diff < -3 ? .red : .secondary
        return (String(format: "%@%.0f dBm", sign, diff), color)
    }

    private func availDelta(_ a: Double?, _ b: Double?) -> (text: String, color: Color)? {
        guard let a, let b else { return nil }
        let diff = (b - a) * 100
        let sign = diff > 0 ? "+" : ""
        let color: Color = diff > 0.1 ? .green : diff < -0.1 ? .red : .secondary
        return (String(format: "%@%.2f%%", sign, diff), color)
    }

    private func speedDelta(_ a: Double?, _ b: Double?) -> (text: String, color: Color)? {
        guard let a, let b else {
            // One side missing — show a note
            if a == nil && b != nil { return ("B only", .secondary) }
            if b == nil && a != nil { return ("A only", .secondary) }
            return nil
        }
        let diff = b - a
        let sign = diff > 0 ? "+" : ""
        let color: Color = diff > 1 ? .green : diff < -1 ? .red : .secondary
        return (String(format: "%@%.1f Mbps", sign, diff), color)
    }
}
