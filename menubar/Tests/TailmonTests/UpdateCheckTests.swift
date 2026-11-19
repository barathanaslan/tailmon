// The "newer release" dot: version comparison, GitHub's answer, how often a
// request may go out, and which upgrade command a copy is offered.
import XCTest

@testable import Tailmon

final class UpdateCheckTests: XCTestCase {
    func testIsNewer() {
        XCTAssertTrue(UpdateCheck.isNewer("0.4.1", than: "0.4.0"))
        XCTAssertTrue(UpdateCheck.isNewer("v0.4.1", than: "0.4.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.10.0", than: "0.9.3")) // numeric, not text
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.4.0", than: "0.4.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.4", than: "0.4.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.3.9", than: "0.4.0"))
        XCTAssertFalse(UpdateCheck.isNewer("0.4.0-rc1", than: "0.4.0"))
        XCTAssertFalse(UpdateCheck.isNewer("garbage", than: "0.4.0"))
    }

    func testParseGitHubAnswer() throws {
        let json = #"{"tag_name":"v0.4.1","html_url":"https://github.com/barathanaslan/tailmon/releases/tag/v0.4.1","draft":false,"assets":[]}"#
        let n = try XCTUnwrap(UpdateCheck.parse(Data(json.utf8)))
        XCTAssertEqual(n.version, "0.4.1")
        XCTAssertEqual(n.page.absoluteString, "https://github.com/barathanaslan/tailmon/releases/tag/v0.4.1")

        // A rate-limit or error body, a page that is not https, a tag that is no version.
        XCTAssertNil(UpdateCheck.parse(Data(#"{"message":"API rate limit exceeded"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"v0.4.1","html_url":"http://example.com/x"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data(#"{"tag_name":"nightly","html_url":"https://example.com/x"}"#.utf8)))
        XCTAssertNil(UpdateCheck.parse(Data("not json".utf8)))
    }

    func testNoticeOnlyForANewerRelease() throws {
        let latest = UpdateNotice(version: "0.4.1", page: try XCTUnwrap(URL(string: "https://example.com/r")))
        XCTAssertEqual(UpdateCheck.notice(latest: latest, current: "0.4.0"), latest)
        XCTAssertNil(UpdateCheck.notice(latest: latest, current: "0.4.1"))
        XCTAssertNil(UpdateCheck.notice(latest: latest, current: "0.5.0"))
        XCTAssertNil(UpdateCheck.notice(latest: latest, current: nil)) // no bundle version: no claim
        XCTAssertNil(UpdateCheck.notice(latest: nil, current: "0.4.0"))
    }

    func testAtMostOneRequestADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateCheck.isDue(now: now, lastChecked: nil, lastAttempt: nil))
        XCTAssertFalse(UpdateCheck.isDue(now: now, lastChecked: now.addingTimeInterval(-3_600), lastAttempt: nil))
        XCTAssertFalse(UpdateCheck.isDue(now: now, lastChecked: now.addingTimeInterval(-86_399), lastAttempt: nil))
        XCTAssertTrue(UpdateCheck.isDue(now: now, lastChecked: now.addingTimeInterval(-86_401), lastAttempt: nil))
        // A failed request is not repeated on every menu open.
        XCTAssertFalse(UpdateCheck.isDue(now: now, lastChecked: nil, lastAttempt: now.addingTimeInterval(-60)))
        XCTAssertTrue(UpdateCheck.isDue(now: now, lastChecked: nil, lastAttempt: now.addingTimeInterval(-3_601)))
    }

    func testLastAnswerRoundTrips() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "tailmon-tests-\(UUID().uuidString)"))
        XCTAssertNil(UpdateCheck.loadLatest(d))
        XCTAssertNil(UpdateCheck.lastChecked(d))
        let latest = UpdateNotice(version: "0.4.1", page: try XCTUnwrap(URL(string: "https://example.com/r")))
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        UpdateCheck.save(latest, at: at, d)
        XCTAssertEqual(UpdateCheck.loadLatest(d), latest)
        XCTAssertEqual(UpdateCheck.lastChecked(d), at)
    }

    func testUpgradeCommandFollowsTheInstall() {
        XCTAssertEqual(UpdateCheck.upgradeCommand(fileExists: { $0 == "/opt/homebrew/Caskroom/tailmon-app" }),
                       "brew upgrade --cask barathanaslan/tailmon/tailmon-app")
        XCTAssertNil(UpdateCheck.upgradeCommand(fileExists: { _ in false })) // built from source
    }

    @MainActor
    func testModelShowsAndClearsTheNotice() throws {
        let model = FleetModel(preview: true)
        XCTAssertNil(model.update)
        let latest = UpdateNotice(version: "0.4.1", page: try XCTUnwrap(URL(string: "https://example.com/r")))
        model.setLatest(latest, current: "0.4.0")
        XCTAssertEqual(model.update, latest)
        model.setLatest(latest, current: "0.4.1") // after the upgrade
        XCTAssertNil(model.update)
    }
}
