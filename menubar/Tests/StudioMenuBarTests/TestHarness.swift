// TestHarness.swift -- tiny XCTest-free / Testing-free test runner.
//
// We can't use XCTest (requires full Xcode, not Command Line Tools) or
// swift-testing (the `_Testing_Foundation` cross-import overlay ships
// without a swiftmodule in the CLT Testing.framework). So we hand-roll a
// 40-line harness and run tests as a plain executable.
//
// Usage: functions with names starting with "test" are registered manually
// in main.swift. Each either returns normally (pass) or throws (fail).

import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case assertion(String, StaticString, UInt)

    var description: String {
        switch self {
        case .assertion(let msg, let file, let line):
            return "\(file):\(line): \(msg)"
        }
    }
}

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "assertion failed",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    if !condition() {
        throw TestFailure.assertion(message(), file, line)
    }
}

func expectEqual<T: Equatable>(
    _ a: @autoclosure () -> T,
    _ b: @autoclosure () -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    let left = a()
    let right = b()
    if left != right {
        let extra = message()
        let hint = extra.isEmpty ? "" : " (\(extra))"
        throw TestFailure.assertion("expected \(right), got \(left)\(hint)", file, line)
    }
}

func expectClose(
    _ a: @autoclosure () -> Double,
    _ b: @autoclosure () -> Double,
    accuracy: Double = 0.001,
    file: StaticString = #file,
    line: UInt = #line
) throws {
    let left = a()
    let right = b()
    if abs(left - right) > accuracy {
        throw TestFailure.assertion("expected ~\(right), got \(left)", file, line)
    }
}

func expectThrows(
    _ body: () throws -> Void,
    _ message: String = "expected throw",
    file: StaticString = #file,
    line: UInt = #line
) throws {
    do {
        try body()
        throw TestFailure.assertion(message, file, line)
    } catch is TestFailure {
        throw TestFailure.assertion(message, file, line)
    } catch {
        // good -- we wanted a throw
    }
}

func expectThrowsAsync(
    _ body: () async throws -> Void,
    _ message: String = "expected throw",
    file: StaticString = #file,
    line: UInt = #line
) async throws {
    do {
        try await body()
    } catch is TestFailure {
        throw TestFailure.assertion(message, file, line)
    } catch {
        return
    }
    throw TestFailure.assertion(message, file, line)
}

struct TestCase {
    let name: String
    let run: () async throws -> Void
}

final class TestRunner {
    private var cases: [TestCase] = []

    func add(_ name: String, _ body: @escaping () throws -> Void) {
        cases.append(TestCase(name: name, run: { try body() }))
    }

    func addAsync(_ name: String, _ body: @escaping () async throws -> Void) {
        cases.append(TestCase(name: name, run: body))
    }

    /// Runs every registered test and prints a pytest-ish summary. Exits
    /// non-zero if any test fails (so CI can pick it up).
    func run() async -> Int {
        var passed = 0
        var failed = 0
        var failures: [(String, String)] = []
        print("Running \(cases.count) tests...")
        for tc in cases {
            do {
                try await tc.run()
                print("  ok   \(tc.name)")
                passed += 1
            } catch let err as TestFailure {
                print("  FAIL \(tc.name): \(err)")
                failures.append((tc.name, String(describing: err)))
                failed += 1
            } catch {
                print("  FAIL \(tc.name): \(error)")
                failures.append((tc.name, String(describing: error)))
                failed += 1
            }
        }
        print("")
        print("\(passed) passed, \(failed) failed")
        if !failures.isEmpty {
            print("")
            print("Failures:")
            for (name, msg) in failures {
                print("  - \(name): \(msg)")
            }
        }
        return failed == 0 ? 0 : 1
    }
}

/// Locate a JSON fixture bundled with the test target. SwiftPM copies the
/// `Fixtures/` subdirectory into the test bundle; `Bundle.module` gives us
/// a handle to it.
func loadFixture(_ name: String) throws -> Data {
    if let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
        return try Data(contentsOf: url)
    }
    if let url = Bundle.module.url(forResource: "Fixtures/" + name, withExtension: "json") {
        return try Data(contentsOf: url)
    }
    throw TestFailure.assertion("fixture not found: \(name).json", #file, #line)
}
