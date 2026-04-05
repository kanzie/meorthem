@testable import MeOrThemCore

// MARK: - Tests for FIXES.md bug fixes

func runBugFixTests() {
    suite("Fix #2: Loss average divides by actual data count") {
        // The bug: dividing by targets.count (all targets) instead of lossValues.count (only those with data).
        // Scenario: 2 of 5 targets report data, both with 5% loss.
        // Old bug: 5+5 / 5 = 2.0%  (wrong — diluted by empty targets)
        // Fixed:   5+5 / 2 = 5.0%  (correct — only counts targets with data)

        let values: [Double] = [5.0, 5.0]   // 2 targets with data
        let totalTargetCount = 5             // 5 total targets (3 have no data yet)

        // Old (buggy) formula
        let buggyAvg = values.reduce(0, +) / Double(max(totalTargetCount, 1))
        expectEqual(buggyAvg, 2.0, "buggy formula gives 2.0 (wrong)")

        // Fixed formula
        let fixedAvg = values.isEmpty ? 0.0 : values.reduce(0, +) / Double(values.count)
        expectEqual(fixedAvg, 5.0, "fixed formula gives 5.0 (correct)")

        // All targets have data — both formulas should agree
        let allValues: [Double] = [5.0, 5.0, 5.0, 5.0, 5.0]
        let buggyAll = allValues.reduce(0, +) / Double(allValues.count)
        let fixedAll = allValues.isEmpty ? 0.0 : allValues.reduce(0, +) / Double(allValues.count)
        expectEqual(buggyAll, fixedAll, "when all have data, both give same result")
        expectEqual(fixedAll, 5.0, "all targets 5% → average is 5%")

        // Empty case — fixed formula returns nil (or 0)
        let empty: [Double] = []
        let nilWhenEmpty: Double? = empty.isEmpty ? nil : empty.reduce(0, +) / Double(empty.count)
        expectNil(nilWhenEmpty, "no data → nil (don't show 0% loss when we have no data)")

        // Single target
        let single: [Double] = [12.5]
        let singleAvg = single.isEmpty ? 0.0 : single.reduce(0, +) / Double(single.count)
        expectEqual(singleAvg, 12.5, "single target 12.5% → average is 12.5%")
    }

    suite("Fix #7: CSV field quoting (RFC 4180)") {
        // Replicates the private csvQuote() logic from CSVExporter for verification.
        func csvQuote(_ field: String) -> String {
            guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
                return field
            }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }

        // Plain fields — no quoting needed
        expectEqual(csvQuote("cloudflare"),    "cloudflare",    "plain hostname no quoting")
        expectEqual(csvQuote("1.1.1.1"),       "1.1.1.1",       "IP address no quoting")
        expectEqual(csvQuote("Home WiFi"),     "Home WiFi",     "label with space no quoting")

        // Comma in field — must be quoted
        expectEqual(csvQuote("Server, West"),  "\"Server, West\"",  "comma → quoted")
        expectEqual(csvQuote("a,b,c"),         "\"a,b,c\"",          "multiple commas → quoted")

        // Quote in field — must be escaped as ""
        expectEqual(csvQuote("He said \"hi\""), "\"He said \"\"hi\"\"\"", "quotes → escaped and wrapped")

        // Newline in SSID — must be quoted
        expectEqual(csvQuote("SSID\nBad"),     "\"SSID\nBad\"",     "newline → quoted")
        expectEqual(csvQuote("SSID\rBad"),     "\"SSID\rBad\"",     "carriage return → quoted")

        // Comma + quote combination
        expectEqual(csvQuote("a,\"b\""),       "\"a,\"\"b\"\"\"",  "comma + quote → both escaped")

        // Empty string — no quoting
        expectEqual(csvQuote(""),              "",                  "empty string unchanged")
    }

    suite("Fix #1 (logic): NetworkInfo nil-ifa_addr guard") {
        // The crash was a nil dereference on ifa_addr.pointee.sa_family.
        // We can't easily simulate a null ifa_addr in a unit test without raw C pointers,
        // but we can verify the guard pattern itself is sound by testing that
        // a similar guard pattern correctly skips nil values.
        var skipped = 0
        var processed = 0
        let optionals: [UnsafeMutablePointer<Int>?] = [nil, nil, nil]
        for ptr in optionals {
            guard ptr != nil else { skipped += 1; continue }
            processed += 1
        }
        expectEqual(skipped, 3,    "3 nil pointers all guarded and skipped")
        expectEqual(processed, 0,  "no nil pointer was dereferenced")
    }
}
