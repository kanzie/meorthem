import Foundation
import os.log

private let log = Logger(subsystem: "com.meorthem", category: "LogExporter")

/// Writes a continuous append-mode daily CSV log to ~/Library/Logs/MeOrThem/.
///
/// On each poll tick the caller passes new ping and WiFi data via `appendPing(_:target:)`
/// and `appendWiFi(_:)`. Rows are written immediately to the open file handle for today.
/// At midnight the current file is flushed, closed, and a new one opened for the new date.
/// Old files are pruned to stay within the configured raw retention window.
///
/// The log is only active when `settings.enableLogRotation` is true.
@MainActor
final class LogExporter {
    private let settings:   AppSettings
    private var fileHandle: FileHandle?
    private var currentDay: String = ""
    private var midnightTimer: Timer?

    private static let _dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let _isoFormatter = ISO8601DateFormatter()

    private static let logDir: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/MeOrThem", isDirectory: true)
    }()

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle (called from AppEnvironment)

    func start() {
        guard settings.enableLogRotation else { return }
        openFileForToday()
        scheduleMidnightRotation()
    }

    func stop() {
        midnightTimer?.invalidate()
        midnightTimer = nil
        closeCurrentFile()
    }

    // MARK: - Append (called on every poll tick)

    func appendPing(_ result: PingResult, target: PingTarget) {
        guard settings.enableLogRotation, let fh = fileHandle else { return }
        let ts     = Self._isoFormatter.string(from: result.timestamp)
        let rtt    = result.rtt.map    { String(format: "%.3f", $0) } ?? ""
        let loss   = String(format: "%.1f", result.lossPercent)
        let jitter = result.jitter.map { String(format: "%.3f", $0) } ?? ""
        let row    = "\(ts),ping,\(csvQuote(target.host)),\(csvQuote(target.label)),\(rtt),\(loss),\(jitter)\n"
        writeRow(row, to: fh)
    }

    func appendWiFi(_ snapshot: WiFiSnapshot) {
        guard settings.enableLogRotation, let fh = fileHandle else { return }
        let ts   = Self._isoFormatter.string(from: snapshot.timestamp)
        let row  = "\(ts),wifi,,,\(snapshot.rssi),\(snapshot.snr),\(snapshot.channelNumber)," +
                   "\(String(format: "%.1f", snapshot.channelBandGHz))," +
                   "\(String(format: "%.0f", snapshot.txRateMbps))\n"
        writeRow(row, to: fh)
    }

    private func writeRow(_ row: String, to fh: FileHandle) {
        do {
            try fh.write(contentsOf: Data(row.utf8))
        } catch {
            log.error("LogExporter: write failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Called by AppEnvironment when the setting changes

    func enabledDidChange(_ enabled: Bool) {
        if enabled {
            openFileForToday()
            scheduleMidnightRotation()
        } else {
            stop()
        }
    }

    // MARK: - Private: file management

    private func openFileForToday() {
        closeCurrentFile()

        let day = Self._dateFormatter.string(from: Date())
        currentDay = day
        let fileURL = Self.logDir.appendingPathComponent("meorthem-\(day).csv")

        do {
            try FileManager.default.createDirectory(at: Self.logDir,
                                                     withIntermediateDirectories: true)
        } catch {
            log.error("LogExporter: cannot create log dir — \(error.localizedDescription)")
            return
        }

        let isNewFile = !FileManager.default.fileExists(atPath: fileURL.path)
        if isNewFile {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let fh = FileHandle(forWritingAtPath: fileURL.path) else {
            log.error("LogExporter: cannot open \(fileURL.lastPathComponent)")
            return
        }

        if isNewFile {
            // Write CSV header for new files
            let header = "Timestamp,Type,Host,Label,Value1,Value2,Value3,Value4,Value5\n"
            fh.write(Data(header.utf8))
        } else {
            fh.seekToEndOfFile()
        }

        fileHandle = fh
        log.info("LogExporter: opened \(fileURL.lastPathComponent, privacy: .public) (new=\(isNewFile))")

        pruneOldLogs()
    }

    private func closeCurrentFile() {
        fileHandle?.synchronizeFile()
        fileHandle?.closeFile()
        fileHandle = nil
    }

    private func scheduleMidnightRotation() {
        midnightTimer?.invalidate()

        let cal = Calendar.current
        guard let tomorrow = cal.nextDate(after: Date(),
                                          matching: DateComponents(hour: 0, minute: 0, second: 0),
                                          matchingPolicy: .nextTime) else { return }
        let delay = tomorrow.timeIntervalSince(Date())

        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rotateMidnight()
            }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        midnightTimer = t
    }

    private func rotateMidnight() {
        log.info("LogExporter: midnight rotation")
        openFileForToday()       // closes old handle, opens new one
        scheduleMidnightRotation()
    }

    private func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.logDir,
                                                       includingPropertiesForKeys: [.creationDateKey],
                                                       options: .skipsHiddenFiles) else { return }
        let maxFiles = settings.rawRetentionDays
        let csvFiles = files
            .filter { $0.pathExtension == "csv" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
        let excess = csvFiles.count - maxFiles
        guard excess > 0 else { return }
        for old in csvFiles.prefix(excess) {
            try? fm.removeItem(at: old)
            log.info("LogExporter: pruned \(old.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: - RFC 4180 quoting

    private func csvQuote(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") ||
              field.contains("\n") || field.contains("\r") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
