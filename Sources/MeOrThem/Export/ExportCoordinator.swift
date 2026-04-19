import AppKit
import PDFKit
import UniformTypeIdentifiers
import MeOrThemCore
import os.log

private let exportLog = Logger(subsystem: "com.meorthem", category: "Export")

@MainActor
final class ExportCoordinator {
    private let store:       MetricStore
    private let settings:    AppSettings
    private let sqliteStore: SQLiteStore

    init(metricStore: MetricStore, settings: AppSettings, sqliteStore: SQLiteStore) {
        self.store       = metricStore
        self.settings    = settings
        self.sqliteStore = sqliteStore
    }

    func exportCSV(from: Date, to: Date) {
        exportLog.info("exportCSV: from=\(from) to=\(to)")
        let gzType = UTType(filenameExtension: "gz") ?? .data
        let panel  = makeSavePanel(name: "Me-Or-Them-Report.csv.gz", types: [gzType])
        showPanel(panel) { [self] url in
            let csv = CSVExporter.exportFromDB(
                sqliteStore: self.sqliteStore,
                targets: self.settings.pingTargets,
                from: from, to: to
            )
            guard let raw = csv.data(using: .utf8) else { return }
            do {
                let compressed = try gzipCompress(raw)
                try compressed.write(to: url)
                exportLog.info("exportCSV: wrote \(compressed.count) bytes (raw \(raw.count))")
            } catch {
                exportLog.error("exportCSV: write failed — \(error.localizedDescription)")
            }
        }
    }

    func exportJSON(from: Date, to: Date) {
        exportLog.info("exportJSON: from=\(from) to=\(to)")
        let gzType = UTType(filenameExtension: "gz") ?? .data
        let panel  = makeSavePanel(name: "Me-Or-Them-Report.json.gz", types: [gzType])
        showPanel(panel) { [self] url in
            do {
                let raw        = try JSONExporter.exportFromDB(
                    sqliteStore: self.sqliteStore,
                    targets: self.settings.pingTargets,
                    from: from, to: to
                )
                let compressed = try gzipCompress(raw)
                try compressed.write(to: url)
                exportLog.info("exportJSON: wrote \(compressed.count) bytes (raw \(raw.count))")
            } catch {
                exportLog.error("exportJSON: failed — \(error.localizedDescription)")
            }
        }
    }

    func exportPDF(from: Date, to: Date) {
        exportLog.info("exportPDF: from=\(from) to=\(to)")
        let panel = makeSavePanel(name: "Me-Or-Them-Report.pdf", types: [.pdf])
        showPanel(panel) { [self] url in
            let speedRows = self.sqliteStore.speedtestRows(from: from, to: to)
            let doc = PDFExporter.exportFromDB(
                sqliteStore: self.sqliteStore,
                targets: self.settings.pingTargets,
                thresholds: self.settings.thresholds,
                speedtestRows: speedRows,
                from: from, to: to
            )
            if doc.write(to: url) {
                exportLog.info("exportPDF: write succeeded")
            } else {
                exportLog.error("exportPDF: PDFDocument.write(to:) returned false")
            }
        }
    }

    // MARK: - Private

    private func showPanel(_ panel: NSSavePanel, completion: @escaping (URL) -> Void) {
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
        if let window = targetWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                completion(url)
            }
        } else {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                    panel.beginSheetModal(for: window) { response in
                        guard response == .OK, let url = panel.url else { return }
                        completion(url)
                    }
                }
            }
        }
    }

    private func makeSavePanel(name: String, types: [UTType]) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.isExtensionHidden = false
        return panel
    }
}

// MARK: - Gzip compression

/// Compresses `data` into a valid gzip stream (RFC 1952).
///
/// Strategy: use Foundation's zlib compressor (RFC 1950 = 2-byte header + deflate + 4-byte
/// Adler-32). Strip the 2-byte zlib header and 4-byte Adler-32 footer to extract raw DEFLATE,
/// then wrap with a gzip header and a CRC-32 + ISIZE trailer.
private func gzipCompress(_ data: Data) throws -> Data {
    // Zlib-compress (RFC 1950). Available macOS 10.15+.
    let zlibData = try (data as NSData).compressed(using: .zlib) as Data

    // Extract raw DEFLATE by stripping the 2-byte zlib header and 4-byte Adler-32 footer.
    guard zlibData.count >= 6 else { throw GzipError.tooShort }
    let rawDeflate = zlibData.dropFirst(2).dropLast(4)

    // Gzip header (10 bytes, RFC 1952 §2.3.1).
    var result = Data(capacity: 10 + rawDeflate.count + 8)
    result.append(contentsOf: [
        0x1f, 0x8b,             // magic number
        0x08,                   // compression method: deflate
        0x00,                   // FLG: no extra fields
        0x00, 0x00, 0x00, 0x00, // MTIME: not set
        0x00,                   // XFL: default compression
        0xff,                   // OS: unknown
    ])
    result.append(rawDeflate)

    // CRC-32 of the original uncompressed data (little-endian).
    let crc = crc32OfData(data)
    result.append(UInt8(crc        & 0xff))
    result.append(UInt8(crc >>  8  & 0xff))
    result.append(UInt8(crc >> 16  & 0xff))
    result.append(UInt8(crc >> 24  & 0xff))

    // ISIZE: original size mod 2^32 (little-endian).
    let size = UInt32(truncatingIfNeeded: data.count)
    result.append(UInt8(size        & 0xff))
    result.append(UInt8(size >>  8  & 0xff))
    result.append(UInt8(size >> 16  & 0xff))
    result.append(UInt8(size >> 24  & 0xff))

    return result
}

private enum GzipError: Error { case tooShort }

/// CRC-32 (ISO 3309 / ITU-T V.42) implemented in pure Swift.
/// Uses the reflected polynomial 0xEDB88320 (≡ 0x04C11DB7 bit-reversed).
private func crc32OfData(_ data: Data) -> UInt32 {
    // Build a 256-entry lookup table at call time.
    // For the export sizes involved this is negligible; a static table would
    // avoid rebuilding it but adds module-level mutable state.
    let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var v = UInt32(i)
        for _ in 0..<8 { v = (v & 1) != 0 ? 0xEDB88320 ^ (v >> 1) : v >> 1 }
        return v
    }
    return ~data.reduce(~UInt32(0)) { crc, byte in
        (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xff)]
    }
}
