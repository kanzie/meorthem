import AppKit
import PDFKit
import MeOrThemCore
import os.log

private let pdfLog = Logger(subsystem: "com.meorthem", category: "PDFExporter")

@MainActor
enum PDFExporter {

    // MARK: - SQLite-backed export (date range aware)

    static func exportFromDB(sqliteStore: SQLiteStore,
                             targets: [PingTarget],
                             thresholds: Thresholds = .default,
                             speedtestRows: [SQLiteStore.SpeedtestRow],
                             from: Date,
                             to: Date) -> PDFDocument {
        pdfLog.info("exportFromDB: targets=\(targets.count) speedtests=\(speedtestRows.count)")
        let pages = buildDBPages(sqliteStore: sqliteStore, targets: targets,
                                 thresholds: thresholds, speedtestRows: speedtestRows,
                                 from: from, to: to)
        return makeDocument(from: pages)
    }

    // MARK: - Layout constants

    private static let pageW:  CGFloat = 595
    private static let pageH:  CGFloat = 842
    private static let margin: CGFloat = 40
    private static let scale:  CGFloat = 2
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()
    private static let localFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - DB-backed page assembly

    private static func buildDBPages(sqliteStore: SQLiteStore,
                                     targets: [PingTarget],
                                     thresholds: Thresholds,
                                     speedtestRows: [SQLiteStore.SpeedtestRow],
                                     from: Date,
                                     to: Date) -> [Data] {
        var pages: [Data] = []
        var page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale)

        // ── Title & period ─────────────────────────────────────────────────
        page.title("Me Or Them — Network Report")
        page.subtitle("Period: \(localFmt.string(from: from)) — \(localFmt.string(from: to))")
        page.gap(14); page.hline(); page.gap(14)

        // ── Ping summary per target ────────────────────────────────────────
        page.sectionHeader("PING TARGETS")
        for target in targets {
            let rows  = sqliteStore.pingRows(for: target.id, from: from, to: to)
            let rtts  = rows.compactMap(\.rttMs)
            let avg   = rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count)
            let loss  = rows.isEmpty ? 0 : rows.map(\.lossPct).reduce(0, +) / Double(rows.count)
            let rttStr  = avg.map  { String(format: "%.1f ms avg", $0) } ?? "no data"
            let lossStr = String(format: "%.1f%% loss", loss)
            page.dotRow(color: .secondaryLabelColor,
                        text: "\(target.label) (\(target.host))  \(rttStr)  \(lossStr)  \(rows.count) samples")
        }
        page.gap(8); page.hline(); page.gap(12)

        // ── Ping history per target ────────────────────────────────────────
        let pingCols: [Col] = [
            Col("Timestamp", 140),
            Col("RTT (ms)",   65),
            Col("Loss (%)",   60),
            Col("Jitter (ms)", 70),
        ]
        for target in targets {
            let rows = sqliteStore.pingRows(for: target.id, from: from, to: to)
            guard !rows.isEmpty else { continue }
            if !page.hasRoom(50) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
            page.sectionHeader("PING HISTORY — \(target.label.uppercased()) (\(target.host))")
            page.tableHeader(pingCols)
            for r in rows {
                if !page.hasRoom(PageCanvas.rowH) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
                page.tableRow([
                    iso.string(from: r.timestamp),
                    r.rttMs.map    { String(format: "%.3f", $0) } ?? "—",
                    String(format: "%.1f", r.lossPct),
                    r.jitterMs.map { String(format: "%.3f", $0) } ?? "—",
                ], cols: pingCols)
            }
            page.gap(6); page.hline(); page.gap(10)
        }

        // ── Bandwidth tests ────────────────────────────────────────────────
        if !speedtestRows.isEmpty {
            if !page.hasRoom(50) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
            let bwCols: [Col] = [
                Col("Timestamp",   140),
                Col("↓ Dl Mbps",    65),
                Col("↑ Ul Mbps",    65),
                Col("Latency ms",   70),
                Col("Jitter ms",    60),
            ]
            page.sectionHeader("BANDWIDTH TESTS")
            page.tableHeader(bwCols)
            for s in speedtestRows {
                if !page.hasRoom(PageCanvas.rowH) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
                page.tableRow([
                    iso.string(from: s.timestamp),
                    String(format: "%.1f", s.downloadMbps),
                    String(format: "%.1f", s.uploadMbps),
                    String(format: "%.1f", s.latencyMs),
                    String(format: "%.1f", s.jitterMs),
                ], cols: bwCols)
            }
            page.gap(6); page.hline(); page.gap(10)
        }

        // ── Wi-Fi history ──────────────────────────────────────────────────
        let wifiRows = sqliteStore.wifiRows(from: from, to: to)
        if !wifiRows.isEmpty {
            let wifiCols: [Col] = [
                Col("Timestamp", 140),
                Col("RSSI",       45),
                Col("SNR",        40),
                Col("Ch",         30),
                Col("GHz",        40),
                Col("Tx Mbps",    55),
            ]
            if !page.hasRoom(50) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
            page.sectionHeader("WI-FI HISTORY")
            page.tableHeader(wifiCols)
            for w in wifiRows {
                if !page.hasRoom(PageCanvas.rowH) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
                page.tableRow([
                    iso.string(from: w.timestamp),
                    "\(w.rssi)",
                    "\(w.snr)",
                    "\(w.channelNumber)",
                    String(format: "%.1f", w.bandGHz),
                    String(format: "%.0f", w.txRateMbps),
                ], cols: wifiCols)
            }
            page.gap(6); page.hline(); page.gap(10)
        }

        // ── DNS resolver summary ───────────────────────────────────────────
        let dnsRawRows = sqliteStore.dnsResolverRows(from: from, to: to)
        if !dnsRawRows.isEmpty {
            var byIP: [String: [SQLiteStore.DNSResolverRow]] = [:]
            for row in dnsRawRows { byIP[row.resolverIP, default: []].append(row) }

            let dnsCols: [Col] = [
                Col("Resolver",  120),
                Col("IP",         90),
                Col("Avg RTT",    65),
                Col("Fail Rate",  60),
                Col("Samples",    55),
            ]
            if !page.hasRoom(50) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
            page.sectionHeader("DNS RESOLVERS")
            page.tableHeader(dnsCols)
            for (ip, rows) in byIP.sorted(by: { $0.key < $1.key }) {
                if !page.hasRoom(PageCanvas.rowH) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
                let name     = rows.first?.resolverName ?? ip
                let rtts     = rows.compactMap(\.resolveMs)
                let avgRTT   = rtts.isEmpty ? "—"
                                           : String(format: "%.1f ms", rtts.reduce(0, +) / Double(rtts.count))
                let failures = rows.filter { $0.resolveMs == nil }.count
                let failRate = rows.isEmpty ? "—"
                                           : String(format: "%.0f%%", Double(failures) / Double(rows.count) * 100)
                page.tableRow([name, ip, avgRTT, failRate, "\(rows.count)"], cols: dnsCols)
            }
        }

        pages.append(page.finish())
        return pages
    }

    private static func makeDocument(from pages: [Data]) -> PDFDocument {
        let document = PDFDocument()
        for (i, data) in pages.enumerated() {
            guard let image = NSImage(data: data), let pg = PDFPage(image: image) else {
                pdfLog.error("makeDocument: page \(i) failed"); continue
            }
            document.insert(pg, at: document.pageCount)
        }
        return document
    }
}

// MARK: - Column descriptor

private struct Col {
    let title: String
    let w: CGFloat
    init(_ title: String, _ w: CGFloat) { self.title = title; self.w = w }
}

// MARK: - PageCanvas

/// Manages a single A4 bitmap page. Save/restore graphics state is balanced: init saves, finish() restores.
private final class PageCanvas {
    static let rowH: CGFloat = 13

    private let pageW, pageH, margin, scale: CGFloat
    private var y: CGFloat
    private let rep: NSBitmapImageRep
    private let footerReserved: CGFloat = 24

    nonisolated(unsafe) private static let titleF  = NSFont.boldSystemFont(ofSize: 18)
    nonisolated(unsafe) private static let subF    = NSFont.systemFont(ofSize: 10)
    nonisolated(unsafe) private static let secF    = NSFont.boldSystemFont(ofSize: 11)
    nonisolated(unsafe) private static let bodyF   = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    nonisolated(unsafe) private static let tableHF = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
    nonisolated(unsafe) private static let footerF = NSFont.systemFont(ofSize: 8)

    init(w: CGFloat, h: CGFloat, margin: CGFloat, scale: CGFloat) {
        self.pageW = w; self.pageH = h; self.margin = margin; self.scale = scale
        self.y = h - margin

        rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        ctx.cgContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = ctx

        NSColor.white.setFill()
        NSBezierPath.fill(CGRect(x: 0, y: 0, width: w, height: h))
        emit("Generated by Me Or Them", pt: NSPoint(x: margin, y: 10), font: Self.footerF, color: .tertiaryLabelColor)
    }

    // MARK: - Availability

    func hasRoom(_ height: CGFloat) -> Bool {
        y - height > footerReserved + 4
    }

    // MARK: - Drawing primitives

    func title(_ text: String) {
        y -= 22
        emit(text, pt: NSPoint(x: margin, y: y), font: Self.titleF, color: .black)
    }

    func subtitle(_ text: String) {
        y -= 14
        emit(text, pt: NSPoint(x: margin, y: y), font: Self.subF, color: .secondaryLabelColor)
    }

    func gap(_ amount: CGFloat) { y -= amount }

    func hline() {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: margin, y: y))
        path.line(to: NSPoint(x: pageW - margin, y: y))
        path.lineWidth = 0.5
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    func sectionHeader(_ text: String) {
        y -= 14
        emit(text, pt: NSPoint(x: margin, y: y), font: Self.secF, color: .secondaryLabelColor)
        y -= 8
    }

    func dotRow(color: NSColor, text: String) {
        let rowH: CGFloat = 17
        let dotSize: CGFloat = 10
        let dotY = y - rowH + (rowH - dotSize) / 2
        let dot = NSBezierPath(ovalIn: NSRect(x: margin, y: dotY, width: dotSize, height: dotSize))
        color.setFill(); dot.fill()
        emit(text, pt: NSPoint(x: margin + 16, y: y - rowH + (rowH - 11) / 2),
             font: Self.bodyF, color: .labelColor)
        y -= rowH
    }

    func bodyLine(_ text: String) {
        y -= 13
        emit(text, pt: NSPoint(x: margin, y: y), font: Self.bodyF, color: .labelColor)
        y -= 2
    }

    func tableHeader(_ cols: [Col]) {
        var x = margin
        for col in cols {
            emit(col.title, pt: NSPoint(x: x, y: y - 12), font: Self.tableHF, color: .secondaryLabelColor)
            x += col.w
        }
        y -= 12
        thinLine(at: y - 2)
        y -= 5
    }

    func tableRow(_ values: [String], cols: [Col]) {
        var x = margin
        for (i, col) in cols.enumerated() {
            emit(i < values.count ? values[i] : "",
                 pt: NSPoint(x: x, y: y - 11), font: Self.bodyF, color: .labelColor)
            x += col.w
        }
        y -= Self.rowH
    }

    func finish() -> Data {
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: - Helpers

    private func thinLine(at lineY: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: margin, y: lineY))
        path.line(to: NSPoint(x: pageW - margin, y: lineY))
        path.lineWidth = 0.3
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    private func emit(_ text: String, pt: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: text,
                           attributes: [.font: font, .foregroundColor: color]).draw(at: pt)
    }
}
