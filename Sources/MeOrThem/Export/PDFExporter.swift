import AppKit
import PDFKit
import os.log

private let pdfLog = Logger(subsystem: "com.meorthem", category: "PDFExporter")

@MainActor
enum PDFExporter {

    static func export(store: MetricStore, targets: [PingTarget], thresholds: Thresholds = .default) -> PDFDocument {
        pdfLog.info("export: entry — targets=\(targets.count)")
        let pages = buildPages(store: store, targets: targets, thresholds: thresholds)
        let document = PDFDocument()
        for (i, data) in pages.enumerated() {
            guard let image = NSImage(data: data), let page = PDFPage(image: image) else {
                pdfLog.error("export: page \(i) failed"); continue
            }
            document.insert(page, at: document.pageCount)
        }
        pdfLog.info("export: done — \(document.pageCount) pages")
        return document
    }

    // MARK: - Layout constants

    private static let pageW:  CGFloat = 595
    private static let pageH:  CGFloat = 842
    private static let margin: CGFloat = 40
    private static let scale:  CGFloat = 2
    nonisolated(unsafe) private static let iso = ISO8601DateFormatter()

    // MARK: - Content assembly

    private static func buildPages(store: MetricStore, targets: [PingTarget], thresholds: Thresholds) -> [Data] {
        var pages: [Data] = []
        var page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale)

        // ── Title & date ───────────────────────────────────────────────────
        page.title("Me Or Them — Network Report")
        page.subtitle(iso.string(from: Date()))
        page.gap(14); page.hline(); page.gap(14)

        // ── Current ping summary ───────────────────────────────────────────
        page.sectionHeader("PING TARGETS")
        for target in targets {
            guard let r = store.latestPing[target.id] else { continue }
            let rttStr  = r.rtt.map  { String(format: "%.1f ms", $0) } ?? "timeout"
            let lossStr = String(format: "%.1f%% loss", r.lossPercent)
            let jitStr  = r.jitter.map { String(format: "±%.1f ms", $0) } ?? ""
            let color   = MetricStatus.forPingResult(r, thresholds: thresholds).color
            page.dotRow(color: color, text: "\(target.label) (\(target.host))  \(rttStr)  \(lossStr)  \(jitStr)")
        }
        page.gap(8); page.hline(); page.gap(12)

        // ── Ping history per target ────────────────────────────────────────
        let pingCols: [Col] = [
            Col("Timestamp",    140),
            Col("RTT (ms)",      65),
            Col("Loss (%)",      60),
            Col("Jitter (ms)",   70),
        ]
        for target in targets {
            let history = store.pingHistory[target.id]?.toArray() ?? []
            guard !history.isEmpty else { continue }

            if !page.hasRoom(50) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
            page.sectionHeader("PING HISTORY — \(target.label.uppercased()) (\(target.host))")
            page.tableHeader(pingCols)

            for r in history {
                if !page.hasRoom(PageCanvas.rowH) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
                page.tableRow([
                    iso.string(from: r.timestamp),
                    r.rtt.map    { String(format: "%.3f", $0) } ?? "—",
                    String(format: "%.1f", r.lossPercent),
                    r.jitter.map { String(format: "%.3f", $0) } ?? "—",
                ], cols: pingCols)
            }
            page.gap(6); page.hline(); page.gap(10)
        }

        // ── Current WiFi snapshot ──────────────────────────────────────────
        if let w = store.latestWifi {
            if !page.hasRoom(70) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
            page.sectionHeader("WI-FI")
            page.bodyLine("SSID: \(w.ssid)  |  BSSID: \(w.bssid)")
            page.bodyLine("RSSI: \(w.rssi) dBm (\(w.rssiQuality))  |  SNR: \(w.snr) dB")
            page.bodyLine("Channel: \(w.channelNumber) (\(String(format: "%.1f", w.channelBandGHz)) GHz)  |  TX Rate: \(String(format: "%.0f Mbps", w.txRateMbps))")
            page.gap(6); page.hline(); page.gap(10)
        }

        // ── WiFi history ───────────────────────────────────────────────────
        let wifiHistory = store.wifiHistory.toArray()
        if !wifiHistory.isEmpty {
            let wifiCols: [Col] = [
                Col("Timestamp", 140),
                Col("SSID",       90),
                Col("RSSI",       45),
                Col("SNR",        40),
                Col("Ch",         30),
                Col("GHz",        40),
                Col("Tx Mbps",    55),
            ]
            if !page.hasRoom(50) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
            page.sectionHeader("WI-FI HISTORY")
            page.tableHeader(wifiCols)
            for w in wifiHistory {
                if !page.hasRoom(PageCanvas.rowH) { pages.append(page.finish()); page = PageCanvas(w: pageW, h: pageH, margin: margin, scale: scale) }
                page.tableRow([
                    iso.string(from: w.timestamp),
                    w.ssid,
                    "\(w.rssi)",
                    "\(w.snr)",
                    "\(w.channelNumber)",
                    String(format: "%.1f", w.channelBandGHz),
                    String(format: "%.0f", w.txRateMbps),
                ], cols: wifiCols)
            }
        }

        pages.append(page.finish())
        return pages
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
