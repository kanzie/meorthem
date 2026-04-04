import Foundation
import os.log

private let log = Logger(subsystem: "com.meorthem", category: "LogExporter")

/// Writes daily CSV summaries to ~/Library/Logs/MeOrThem/.
/// Rotates to a new file at midnight; keeps the last 30 days automatically.
@MainActor
final class LogExporter {
    private let metricStore: MetricStore
    private let settings:    AppSettings
    private var dailyTimer:  Timer?

    private static let kMaxRotatedFiles = 30
    private static let logDir: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Logs/MeOrThem", isDirectory: true)
    }()

    init(metricStore: MetricStore, settings: AppSettings) {
        self.metricStore = metricStore
        self.settings    = settings
    }

    // MARK: - Public

    func scheduleDaily() {
        cancelSchedule()
        exportIfNewDay()   // check immediately on launch

        // Fire at next midnight, then every 24h
        let now          = Date()
        let cal          = Calendar.current
        guard let tomorrow = cal.nextDate(after: now,
                                          matching: DateComponents(hour: 0, minute: 0, second: 0),
                                          matchingPolicy: .nextTime) else { return }
        let delay = tomorrow.timeIntervalSince(now)

        let t = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.exportToday()
                self?.scheduleDailyRepeating()
            }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        dailyTimer = t
    }

    func cancelSchedule() {
        dailyTimer?.invalidate()
        dailyTimer = nil
    }

    // MARK: - Private

    private func scheduleDailyRepeating() {
        dailyTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.exportToday() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        dailyTimer = t
    }

    private func exportIfNewDay() {
        let today    = todayFileName()
        let fileURL  = Self.logDir.appendingPathComponent(today)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            exportToday()
        }
    }

    private func exportToday() {
        let csv     = CSVExporter.export(store: metricStore, targets: settings.pingTargets)
        let fileURL = Self.logDir.appendingPathComponent(todayFileName())

        do {
            try FileManager.default.createDirectory(at: Self.logDir,
                                                     withIntermediateDirectories: true)
            try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            log.info("LogExporter: wrote \(fileURL.lastPathComponent)")
            pruneOldLogs()
        } catch {
            log.error("LogExporter: failed to write \(fileURL.path) — \(error.localizedDescription)")
        }
    }

    private func pruneOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.logDir,
                                                       includingPropertiesForKeys: [.creationDateKey],
                                                       options: .skipsHiddenFiles) else { return }
        let csvFiles = files.filter { $0.pathExtension == "csv" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
        let excess = csvFiles.count - Self.kMaxRotatedFiles
        guard excess > 0 else { return }
        for old in csvFiles.prefix(excess) {
            try? fm.removeItem(at: old)
            log.info("LogExporter: pruned \(old.lastPathComponent)")
        }
    }

    private func todayFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "meorthem-\(f.string(from: Date())).csv"
    }
}
