import Foundation
import XCTest

extension XCTestCase {
    /// A throwaway UserDefaults suite for one test, kept out of
    /// ~/Library/Preferences: a suite named by an absolute path is stored at
    /// that path, here in a fresh temporary folder that is removed when the
    /// test ends. (A plain "tailmon-tests-<uuid>" suite left one plist per run
    /// in Preferences, and deleting it there loses to cfprefsd's late writes.)
    func scratchDefaults() throws -> UserDefaults {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailmon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let d = try XCTUnwrap(UserDefaults(suiteName: dir.appendingPathComponent("defaults").path))
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return d
    }
}
