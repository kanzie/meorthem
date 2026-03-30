import Foundation

// Minimal test framework — no XCTest dependency, works with Command Line Tools.

nonisolated(unsafe) var _passCount = 0
nonisolated(unsafe) var _failCount = 0
nonisolated(unsafe) var _currentSuite = ""

func suite(_ name: String, _ body: () -> Void) {
    _currentSuite = name
    print("\n  \(name)")
    body()
    _currentSuite = ""
}

func expect(_ condition: @autoclosure () -> Bool,
            _ message: String = "",
            file: String = #file, line: Int = #line) {
    if condition() {
        _passCount += 1
        print("    ✅ \(message.isEmpty ? "pass" : message)")
    } else {
        _failCount += 1
        let location = URL(fileURLWithPath: file).lastPathComponent
        print("    ❌ FAIL: \(message.isEmpty ? "assertion" : message)  [\(location):\(line)]")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T,
                                _ message: String = "",
                                file: String = #file, line: Int = #line) {
    let pass = a == b
    if pass {
        _passCount += 1
        print("    ✅ \(message.isEmpty ? "\(a) == \(b)" : message)")
    } else {
        _failCount += 1
        let location = URL(fileURLWithPath: file).lastPathComponent
        let msg = message.isEmpty ? "\(a) ≠ \(b)" : "\(message) — got \(a), expected \(b)"
        print("    ❌ FAIL: \(msg)  [\(location):\(line)]")
    }
}

func expectNil<T>(_ value: T?,
                   _ message: String = "",
                   file: String = #file, line: Int = #line) {
    if value == nil {
        _passCount += 1
        print("    ✅ \(message.isEmpty ? "is nil" : message)")
    } else {
        _failCount += 1
        let location = URL(fileURLWithPath: file).lastPathComponent
        print("    ❌ FAIL: expected nil but got \(value!)  [\(location):\(line)]")
    }
}

func expectNotNil<T>(_ value: T?,
                      _ message: String = "",
                      file: String = #file, line: Int = #line) {
    if value != nil {
        _passCount += 1
        print("    ✅ \(message.isEmpty ? "is not nil" : message)")
    } else {
        _failCount += 1
        let location = URL(fileURLWithPath: file).lastPathComponent
        print("    ❌ FAIL: expected non-nil  [\(location):\(line)]")
    }
}

func expectThrows(_ message: String = "",
                   file: String = #file, line: Int = #line,
                   _ body: () throws -> Void) {
    do {
        try body()
        _failCount += 1
        let location = URL(fileURLWithPath: file).lastPathComponent
        print("    ❌ FAIL: expected throw but succeeded  [\(location):\(line)]")
    } catch {
        _passCount += 1
        print("    ✅ \(message.isEmpty ? "threw as expected" : message)")
    }
}

func expectNoThrow(_ message: String = "",
                    file: String = #file, line: Int = #line,
                    _ body: () throws -> Void) {
    do {
        try body()
        _passCount += 1
        print("    ✅ \(message.isEmpty ? "no throw" : message)")
    } catch {
        _failCount += 1
        let location = URL(fileURLWithPath: file).lastPathComponent
        print("    ❌ FAIL: unexpected throw \(error)  [\(location):\(line)]")
    }
}

func printSummary() {
    let total = _passCount + _failCount
    print("\n─────────────────────────────────────")
    if _failCount == 0 {
        print("✅  All \(total) tests passed")
    } else {
        print("❌  \(_failCount) of \(total) tests FAILED")
    }
    print("─────────────────────────────────────\n")
}
