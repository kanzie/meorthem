import Foundation

struct ParsedPing {
    let rtts: [Double]
    let lossPercent: Double
}

enum PingParser {

    // Pre-compiled patterns (static — avoids re-compilation on every parse)
    private static let rttPattern  = try! NSRegularExpression(pattern: "time=(\\d+\\.?\\d*) ms")
    private static let lossPattern = try! NSRegularExpression(pattern: "(\\d+\\.?\\d*)% packet loss")

    static func parse(_ output: String) -> ParsedPing {
        let rtts = extractRTTs(from: output)
        let loss = extractLoss(from: output) ?? (rtts.isEmpty ? 100.0 : 0.0)
        return ParsedPing(rtts: rtts, lossPercent: loss)
    }

    private static func extractRTTs(from text: String) -> [Double] {
        let range = NSRange(text.startIndex..., in: text)
        let matches = rttPattern.matches(in: text, range: range)
        return matches.compactMap { match -> Double? in
            guard let r = Range(match.range(at: 1), in: text),
                  let v = Double(text[r]),
                  v > 0 else { return nil }
            return v
        }
    }

    private static func extractLoss(from text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = lossPattern.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[r])
    }
}
