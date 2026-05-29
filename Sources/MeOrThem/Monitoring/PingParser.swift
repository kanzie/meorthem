import Foundation

struct ParsedPing {
    let rtts: [Double]
    let lossPercent: Double
}

enum PingParser {

    // Pre-compiled patterns (static — avoids re-compilation on every parse).
    // Using a closure with preconditionFailure so any future pattern typo produces a
    // clear diagnostic instead of a bare EXC_BAD_INSTRUCTION from try!.
    private static let rttPattern: NSRegularExpression = {
        guard let re = try? NSRegularExpression(pattern: "time=(\\d+\\.?\\d*) ms") else {
            preconditionFailure("PingParser: invalid rttPattern regex")
        }
        return re
    }()
    private static let lossPattern: NSRegularExpression = {
        guard let re = try? NSRegularExpression(pattern: "(\\d+\\.?\\d*)% packet loss") else {
            preconditionFailure("PingParser: invalid lossPattern regex")
        }
        return re
    }()

    static func parse(_ output: String) -> ParsedPing {
        let rtts = extractRTTs(from: output)
        let loss = extractLoss(from: output) ?? (rtts.isEmpty ? 100.0 : 0.0)
        return ParsedPing(rtts: rtts, lossPercent: loss)
    }

    private static func extractRTTs(from text: String) -> [Double] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = rttPattern.matches(in: text, range: range)
        return matches.compactMap { match -> Double? in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[r])
        }
    }

    private static func extractLoss(from text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = lossPattern.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }
}
