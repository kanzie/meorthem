@preconcurrency import Foundation

public extension Process {
    /// Runs the process and returns stdout as a String using async/await.
    /// Uses readabilityHandler for event-driven I/O — does NOT block any GCD thread
    /// while waiting for output. This prevents GCD thread-pool exhaustion when many
    /// processes run concurrently (e.g. repeated ping polls).
    /// If the process does not complete within `timeout` seconds it is forcibly terminated
    /// and the call throws `ProcessError.timeout`.
    enum ProcessError: Error { case timeout }

    func runAsync(timeout: TimeInterval = 30) async throws -> (stdout: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let outPipe = Pipe()
            standardOutput = outPipe
            standardError  = Pipe()

            // Thread-safe accumulator + once-fire guard.
            final class State: @unchecked Sendable {
                private let lock = NSLock()
                private var _data = Data()
                private var _fired = false

                func append(_ d: Data) {
                    lock.lock(); _data.append(d); lock.unlock()
                }

                // Reads accumulated data — only safe to call after I/O is stopped.
                var data: Data { lock.lock(); defer { lock.unlock() }; return _data }

                func finish(_ body: () -> Void) {
                    lock.lock(); defer { lock.unlock() }
                    guard !_fired else { return }
                    _fired = true
                    body()
                }
            }
            let state = State()

            // Event-driven pipe drain — never holds a GCD thread while waiting.
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { state.append(chunk) }
            }

            // Watchdog: kill the process if it exceeds the timeout.
            let watchdog = DispatchWorkItem { [weak self] in
                outPipe.fileHandleForReading.readabilityHandler = nil
                self?.terminate()
                state.finish { continuation.resume(throwing: ProcessError.timeout) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

            terminationHandler = { process in
                watchdog.cancel()
                // Stop the handler before the final drain so we don't race on appends.
                outPipe.fileHandleForReading.readabilityHandler = nil
                // Process is dead → write end is closed → readDataToEndOfFile returns immediately.
                let tail = outPipe.fileHandleForReading.readDataToEndOfFile()
                state.append(tail)
                let text = String(data: state.data, encoding: .utf8) ?? ""
                state.finish { continuation.resume(returning: (text, process.terminationStatus)) }
            }

            do {
                try run()
            } catch {
                watchdog.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                state.finish { continuation.resume(throwing: error) }
            }
        }
    }
}
