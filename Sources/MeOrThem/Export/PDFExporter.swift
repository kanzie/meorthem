import AppKit
import PDFKit
import os.log

private let pdfLog = Logger(subsystem: "com.meorthem", category: "PDFExporter")

@MainActor
enum PDFExporter {
    static func export(store: MetricStore, targets: [PingTarget], thresholds: Thresholds = .default) -> PDFDocument {
        pdfLog.info("export: entry — thread=\(Thread.isMainThread ? "main" : "background"), targets=\(targets.count)")
        let pageSize = CGRect(x: 0, y: 0, width: 595, height: 842)  // A4
        let document = PDFDocument()
        let data = renderPage(store: store, targets: targets, thresholds: thresholds, pageSize: pageSize)
        pdfLog.info("export: renderPage returned \(data.count) bytes")

        if let image = NSImage(data: data) {
            pdfLog.info("export: NSImage created from data, size=\(image.size.width)x\(image.size.height)")
            if let page = PDFPage(image: image) {
                document.insert(page, at: 0)
                pdfLog.info("export: PDFPage inserted, pageCount=\(document.pageCount)")
            } else {
                pdfLog.error("export: PDFPage(image:) returned nil — data.count=\(data.count)")
            }
        } else {
            pdfLog.error("export: NSImage(data:) returned nil — data.count=\(data.count)")
        }
        return document
    }

    // MARK: - Render to bitmap

    private static func renderPage(store: MetricStore, targets: [PingTarget], thresholds: Thresholds, pageSize: CGRect) -> Data {
        let scale: CGFloat = 2  // Retina
        let bitmapSize = NSSize(width: pageSize.width * scale, height: pageSize.height * scale)
        pdfLog.info("renderPage: bitmapSize=\(bitmapSize.width)x\(bitmapSize.height)")

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bitmapSize.width),
            pixelsHigh: Int(bitmapSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            pdfLog.error("renderPage: NSBitmapImageRep init returned nil — returning empty data")
            return Data()
        }
        pdfLog.info("renderPage: NSBitmapImageRep created")

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            pdfLog.error("renderPage: NSGraphicsContext(bitmapImageRep:) returned nil")
            return Data()
        }
        pdfLog.info("renderPage: NSGraphicsContext created, drawing content")

        NSGraphicsContext.saveGraphicsState()
        ctx.cgContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.current = ctx

        drawContent(store: store, targets: targets, thresholds: thresholds, in: pageSize)

        NSGraphicsContext.restoreGraphicsState()
        pdfLog.info("renderPage: drawing complete, generating PNG data")
        let data = rep.representation(using: .png, properties: [:]) ?? Data()
        pdfLog.info("renderPage: PNG data size=\(data.count)")
        return data
    }

    private static func drawContent(store: MetricStore, targets: [PingTarget], thresholds: Thresholds, in rect: CGRect) {
        // Background
        NSColor.white.setFill()
        NSBezierPath.fill(rect)

        let margin: CGFloat = 40
        var y = rect.height - margin

        // Title
        y = drawText("Me Or Them — Network Report",
                     at: NSPoint(x: margin, y: y - 24),
                     font: .boldSystemFont(ofSize: 18),
                     color: .black)
        y -= 4
        y = drawText(ISO8601DateFormatter().string(from: Date()),
                     at: NSPoint(x: margin, y: y - 14),
                     font: .systemFont(ofSize: 10),
                     color: .secondaryLabelColor)
        y -= 20

        // Separator
        drawLine(from: NSPoint(x: margin, y: y), to: NSPoint(x: rect.width - margin, y: y))
        y -= 20

        // Ping section
        y = drawText("PING TARGETS",
                     at: NSPoint(x: margin, y: y - 14),
                     font: .boldSystemFont(ofSize: 12),
                     color: .secondaryLabelColor)
        y -= 8

        for target in targets {
            guard let r = store.latestPing[target.id] else { continue }
            let rttStr  = r.rtt.map { String(format: "%.1f ms", $0) } ?? "timeout"
            let lossStr = String(format: "%.1f%% loss", r.lossPercent)
            let jitStr  = r.jitter.map { String(format: "±%.1f ms", $0) } ?? ""

            let dot = NSBezierPath(ovalIn: NSRect(x: margin, y: y - 10, width: 10, height: 10))
            let status = MetricStatus.forPingResult(r, thresholds: thresholds)
            status.color.setFill()
            dot.fill()

            y = drawText("\(target.label) (\(target.host))  \(rttStr)  \(lossStr)  \(jitStr)",
                         at: NSPoint(x: margin + 16, y: y - 13),
                         font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                         color: .labelColor)
            y -= 4
        }

        y -= 12
        drawLine(from: NSPoint(x: margin, y: y), to: NSPoint(x: rect.width - margin, y: y))
        y -= 20

        // WiFi section
        if let w = store.latestWifi {
            y = drawText("WI-FI",
                         at: NSPoint(x: margin, y: y - 14),
                         font: .boldSystemFont(ofSize: 12),
                         color: .secondaryLabelColor)
            y -= 8
            let lines = [
                "SSID: \(w.ssid)  |  BSSID: \(w.bssid)",
                "RSSI: \(w.rssi) dBm (\(w.rssiQuality))  |  SNR: \(w.snr) dB",
                "Channel: \(w.channelNumber) (\(String(format: "%.1f", w.channelBandGHz)) GHz)  |  TX Rate: \(String(format: "%.0f Mbps", w.txRateMbps))",
            ]
            for line in lines {
                y = drawText(line,
                             at: NSPoint(x: margin, y: y - 13),
                             font: .monospacedSystemFont(ofSize: 10, weight: .regular),
                             color: .labelColor)
                y -= 4
            }
        }

        // Footer
        drawText("Generated by Me Or Them",
                 at: NSPoint(x: margin, y: 20),
                 font: .systemFont(ofSize: 9),
                 color: .tertiaryLabelColor)
    }

    @discardableResult
    private static func drawText(_ text: String, at point: NSPoint,
                                  font: NSFont, color: NSColor) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        str.draw(at: point)
        return point.y
    }

    private static func drawLine(from: NSPoint, to: NSPoint) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 0.5
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}
