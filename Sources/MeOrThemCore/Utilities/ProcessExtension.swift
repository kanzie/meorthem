import Foundation

public extension Process {
    /// Runs the process and returns stdout as a String using async/await.
    /// Reads stdout in a background thread to prevent pipe buffer deadlock (>64KB output).
    func runAsync() async throws -> (stdout: String, exitCode: Int32) {
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

            terminationHandler = { process in
                readDone.wait()
                let text = String(data: box.data, encoding: .utf8) ?? ""
                continuation.resume(returning: (text, process.terminationStatus))
            }

            do {
                try run()
            } catch {
                // Close the write end so the background reader unblocks, then throw.
                outPipe.fileHandleForWriting.closeFile()
                readDone.wait()
                continuation.resume(throwing: error)
            }
        }
    }
}
