import Foundation

public extension Process {
    /// Runs the process and returns stdout as a String using async/await.
    /// Reads stdout in a background thread to prevent pipe buffer deadlock (>64KB output).
    /// If the process does not complete within `timeout` seconds it is forcibly terminated
    /// and the call throws `ProcessError.timeout`.
    enum ProcessError: Error { case timeout }

    func runAsync(timeout: TimeInterval = 30) async throws -> (stdout: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let outPipe = Pipe()
            let errPipe = Pipe()
            standardOutput = outPipe
            standardError  = errPipe

            // Reference-type box allows cross-thread data hand-off without a data race:
            // the semaphore ensures the writer completes before the reader observes the value.
            final class Box: @unchecked Sendable { var data = Data() }
            let box = Box()
            let readDone = DispatchSemaphore(value: 0)

            // Drain the pipe in the background to avoid the 64KB buffer deadlock.
            DispatchQueue.global(qos: .utility).async {
                box.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                readDone.signal()
            }

            // One-shot flag: whichever path fires first (normal exit or watchdog) wins.
            // Subsequent calls are no-ops — prevents double-resume of the continuation.
            final class Once: @unchecked Sendable {
                private let lock = NSLock()
                private var fired = false
                func fire(_ body: () -> Void) {
                    lock.lock(); defer { lock.unlock() }
                    guard !fired else { return }
                    fired = true
                    body()
                }
            }
            let once = Once()

            // Watchdog: kill the process if it exceeds the timeout.
            // Uses the once-flag so it is harmless if the process already finished.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.terminate()
                // Closing the write end unblocks readDataToEndOfFile.
                outPipe.fileHandleForWriting.closeFile()
                readDone.wait()
                once.fire { continuation.resume(throwing: ProcessError.timeout) }
            }

            terminationHandler = { process in
                readDone.wait()
                let text = String(data: box.data, encoding: .utf8) ?? ""
                once.fire { continuation.resume(returning: (text, process.terminationStatus)) }
            }

            do {
                try run()
            } catch {
                // Close the write end so the background reader unblocks, then throw.
                outPipe.fileHandleForWriting.closeFile()
                readDone.wait()
                once.fire { continuation.resume(throwing: error) }
            }
        }
    }
}
