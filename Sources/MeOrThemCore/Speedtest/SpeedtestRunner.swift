import Foundation
import Combine

public enum SpeedtestState {
    case idle
    case running
    case completed(SpeedtestResult)
    case failed(String)
    case unavailable(String)   // binary missing or invalid
}

@MainActor
public final class SpeedtestRunner: ObservableObject {
    @Published public private(set) var state: SpeedtestState = .idle
    @Published public private(set) var lastRunDate: Date? = {
        let t = UserDefaults.standard.double(forKey: "speedtestLastRunDate")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()
    @Published public private(set) var lastResultSummary: String? = UserDefaults.standard.string(forKey: "speedtestLastResultSummary")
    /// Non-nil while waiting between retry attempts: (current attempt, max attempts).
    @Published public private(set) var retryAttempt: (current: Int, max: Int)? = nil

    private static let maxRetries = 3
    private static let retryDelay: UInt64 = 4_000_000_000 // 4 seconds in nanoseconds

    private var runningTask: Task<Void, Never>?
    private var runningProcess: Process?

    public init() {}

    public func run() {
        if case .running = state { return }
        runningTask?.cancel()
        runningProcess?.terminate()
        runningProcess = nil
        state = .running
        retryAttempt = nil

        runningTask = Task {
            var lastResult: SpeedtestState = .failed("Unknown error")
            for attempt in 1...Self.maxRetries {
                if Task.isCancelled { return }
                let result = await self.executeSpeedtest()
                if case .failed(let msg) = result, self.isRetryable(message: msg), attempt < Self.maxRetries {
                    self.retryAttempt = (attempt + 1, Self.maxRetries)
                    try? await Task.sleep(nanoseconds: Self.retryDelay)
                    self.retryAttempt = nil
                    lastResult = result
                    continue
                }
                lastResult = result
                break
            }
            if !Task.isCancelled {
                self.state = lastResult
                self.retryAttempt = nil
                if case .completed(let r) = lastResult {
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

    /// Returns true for transient failures that are worth retrying (SIGTERM / timeout / launch failure).
    private func isRetryable(message: String) -> Bool {
        // Exit code 15 = SIGTERM (OS killed the process or our watchdog fired).
        // "timed out" covers ProcessError.timeout from runAsync.
        // "ProcessError" = NSTask launch failure, common after wake-from-sleep or at startup
        //   before the network stack is ready (NSTask.ProcessError error 0).
        message.contains("Exit code 15")
            || message.lowercased().contains("timed out")
            || message.contains("ProcessError")
    }

    public func cancel() {
        runningTask?.cancel()
        runningProcess?.terminate()
        runningProcess = nil
        state = .idle
        retryAttempt = nil
    }

    public var summaryText: String {
        switch state {
        case .idle:               return lastResultSummary ?? ""
        case .running:
            if let retry = retryAttempt {
                return "Retrying (\(retry.current)/\(retry.max))…"
            }
            return "Running…"
        case .unavailable(let m): return m
        case .failed(let m):      return "Failed: \(m)"
        case .completed(let r):   return "↓\(r.downloadFormatted)  ↑\(r.uploadFormatted)  \(r.latencyFormatted)"
        }
    }

    public var lastCheckedText: String {
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
            // Verify via code signature rather than SHA-256: signing modifies binary bytes,
            // so a hash would break on every build. codesign --verify detects tampering
            // regardless of which identity signed the binary.
            try BinaryVerifier.verifySignature(at: binaryPath)
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
