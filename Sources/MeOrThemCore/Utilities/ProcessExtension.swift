import Foundation

public extension Process {
    /// Runs the process and returns stdout as a String using async/await.
    /// Uses terminationHandler + CheckedContinuation — never blocks a thread.
    func runAsync() async throws -> (stdout: String, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let outPipe = Pipe()
            let errPipe = Pipe()
            standardOutput = outPipe
            standardError  = errPipe

            terminationHandler = { process in
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (text, process.terminationStatus))
            }

            do {
                try run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
