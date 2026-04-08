import Foundation
import Combine
import MeOrThemCore   // for BinaryVerifier (Bug 15: removed duplicate from MeOrThem/Utilities)

enum SpeedtestState {
    case idle
    case running
    case completed(SpeedtestResult)
    case failed(String)
    case unavailable(String)   // binary missing or invalid
}

@MainActor
final class SpeedtestRunner: ObservableObject {
    @Published private(set) var state: SpeedtestState = .idle
    @Published private(set) var lastRunDate: Date? = {
        let t = UserDefaults.standard.double(forKey: "speedtestLastRunDate")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    @Published private(set) var lastResultSummary: String? = UserDefaults.standard.string(forKey: "speedtestLastResultSummary")

    private var runningTask: Task<Void, Never>?
    private var runningProcess: Process?

    func run() {
        if case .running = state { return }
        runningTask?.cancel()
        runningProcess?.terminate()
        runningProcess = nil
        state = .running

        runningTask = Task {
            let result = await self.executeSpeedtest()
            if !Task.isCancelled {
                self.state = result
                if case .completed(let r) = result {
                    let now = Date()
                    self.lastRunDate = now
                    UserDefaults.standard.set(now.timeIntervalSince1970,
                                              forKey: "speedtestLastRunDate")
                    let summary = "↓\(r.downloadFormatted)  ↑\(r.uploadFormatted)  \(r.latencyFormatted)"
                    self.lastResultSummary = summary
                    UserDefaults.standard.set(summary, forKey: "speedtestLastResultSummary")
                }
            }
        }
    }

    func cancel() {
        runningTask?.cancel()
        runningProcess?.terminate()
        runningProcess = nil
        state = .idle
    }

    var summaryText: String {
        switch state {
        case .idle:               return lastResultSummary ?? ""
        case .running:            return "Running…"
        case .unavailable(let m): return m
        case .failed(let m):      return "Failed: \(m)"
        case .completed(let r):   return "↓\(r.downloadFormatted)  ↑\(r.uploadFormatted)  \(r.latencyFormatted)"
        }
    }

    var lastCheckedText: String {
        guard let date = lastRunDate else { return "Not Checked" }
        let timeStr = Self._timeFormatter.string(from: date)
        if Calendar.current.isDateInToday(date) {
            return "Last checked: Today \(timeStr)"
        } else {
            return "Last checked: \(Self._dateFormatter.string(from: date)), \(timeStr)"
        }
    }

    private static let _timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let _dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: - Private

    private func executeSpeedtest() async -> SpeedtestState {
        let binaryPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/speedtest").path
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            return .unavailable("Speedtest binary not found")
        }

        do {
            try BinaryVerifier.verify(at: binaryPath)
        } catch let e as BinaryVerifier.Error {
            return .unavailable(e.errorDescription ?? "Binary invalid")
        } catch {
            return .unavailable("Binary verification failed")
        }

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binaryPath) else {
            return .unavailable("Speedtest binary is not executable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--format=json", "--accept-license", "--accept-gdpr"]
        self.runningProcess = process

        defer { self.runningProcess = nil }

        do {
            let (stdout, exitCode) = try await process.runAsync()
            guard exitCode == 0 else {
                return .failed("Exit code \(exitCode)")
            }
            let result = try SpeedtestParser.parse(stdout)
            return .completed(result)
        } catch let e as SpeedtestParser.Error {
            return .failed(e.errorDescription ?? "Parse error")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
