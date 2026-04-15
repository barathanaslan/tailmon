// TestMain.swift -- test runner entry point.
//
// The file is deliberately NOT named main.swift because Swift refuses to
// combine top-level code with @main, and we need @main to support
// `async` in the entry point (otherwise a DispatchSemaphore deadlocks
// against the cooperative thread pool on the main actor).
//
// Run with:  swift run --package-path menubar StudioMenuBarTests

import Foundation

@main
struct TestMain {
    static func main() async {
        let runner = TestRunner()
        ModelsTests.register(runner)
        StudioClientTests.register(runner)
        ConfigTests.register(runner)
        PollingServiceTests.register(runner)
        let exitCode = await runner.run()
        exit(Int32(exitCode))
    }
}
