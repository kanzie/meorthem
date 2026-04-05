import Foundation
import Combine

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

    private var runningTask: Task<Void, Never>?

    func run() {
        if case .running = state { return }
        runningTask?.cancel()
        state = .running

        runningTask = Task {
            let result = await Self.executeSpeedtest()
            if !Task.isCancelled {
                self.state = result
                if case .completed = result {
                    let now = Date()
                    self.lastRunDate = now
                    UserDefaults.standard.set(now.timeIntervalSince1970,
                                              forKey: "speedtestLastRunDate")
                }
            }
        }
    }

    func cancel() {
        runningTask?.cancel()
        state = .idle
    }

    var summaryText: String {
        switch state {
        case .idle:               return speedResultLine()
        case .running:            return "Running…"
        case .unavailable(let m): return m
        case .failed(let m):      return "Failed: \(m)"
        case .completed(let r):   return "↓\(r.downloadFormatted)  ↑\(r.uploadFormatted)  \(r.latencyFormatted)"
        }
    }

    var lastCheckedText: String {
        guard let date = lastRunDate else { return "Not Checked" }
        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timeStr = formatter.string(from: date)
        if cal.isDateInToday(date) {
            return "Last checked: Today \(timeStr)"
        } else {
            let df = DateFormatter()
            df.dateFormat = "MMM d"
            return "Last checked: \(df.string(from: date)), \(timeStr)"
        }
    }

    // MARK: - Private

    private func speedResultLine() -> String {
        // When idle with a prior result we may have lost it on restart — show "Not checked"
        return "Not checked"
    }

    private static func executeSpeedtest() async -> SpeedtestState {
        // Locate binary in app bundle
        guard let binaryPath = Bundle.main.path(forResource: "speedtest", ofType: nil) else {
            return .unavailable("Speedtest binary not found")
        }

        // Verify it is a real, non-empty binary
        do {
            try BinaryVerifier.verify(at: binaryPath)
        } catch let e as BinaryVerifier.Error {
            return .unavailable(e.errorDescription ?? "Binary invalid")
        } catch {
            return .unavailable("Binary verification failed")
        }

        // Ensure it's executable
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binaryPath) else {
            return .unavailable("Speedtest binary is not executable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        // Args as array — no shell, no injection
        process.arguments = ["--format=json", "--accept-license", "--accept-gdpr"]

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
