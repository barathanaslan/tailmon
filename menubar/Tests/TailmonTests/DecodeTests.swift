// Decode tests against a fixture captured from real `tailmon json --top 10`
// output (Windows host spliced in from real captured agent values — the box
// was off when the fixture was made and must not be woken for tests).
import XCTest

@testable import Tailmon

final class DecodeTests: XCTestCase {
    func loadFixture() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/fleet", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testDecodeFleetReport() throws {
        let report = try tailmonJSONDecoder().decode(Report.self, from: loadFixture())
        XCTAssertEqual(report.schema, 1)
        XCTAssertGreaterThanOrEqual(report.hosts.count, 3)

        let mac = try XCTUnwrap(report.hosts.first { $0.host == "barathans-macstudio" })
        XCTAssertTrue(mac.isLive)
        let macStats = try XCTUnwrap(mac.stats)
        XCTAssertGreaterThan(macStats.mem.totalMb, 0)
        XCTAssertNotNil(macStats.topProcs)
        XCTAssertFalse(try XCTUnwrap(macStats.topProcs).isEmpty)

        let win = try XCTUnwrap(report.hosts.first { $0.host == "barathans-5070" })
        let winStats = try XCTUnwrap(win.stats)
        let gpu = try XCTUnwrap(winStats.gpu?.first)
        XCTAssertEqual(gpu.name, "NVIDIA GeForce RTX 5070 Ti")
        XCTAssertEqual(gpu.vramTotalMb, 16303)
        XCTAssertEqual(gpu.tempC, 34)
        XCTAssertEqual(winStats.disks?.count, 2)
        XCTAssertEqual(winStats.topProcs?.first?.command, #"C:\Tools\tailmon\tailmon.exe agent"#)
    }

    func testIconInfo() throws {
        let report = try tailmonJSONDecoder().decode(Report.self, from: loadFixture())
        let s = try XCTUnwrap(report.hosts.first { $0.host == "barathans-macstudio" }?.stats)
        let info = IconInfo.make(stats: s, peers: [])
        XCTAssertNotNil(info.cpu)
        let ram = try XCTUnwrap(info.ram)
        let expected = Int((100 * Double(s.mem.usedMb) / Double(s.mem.totalMb)).rounded())
        XCTAssertEqual(ram, expected)
        // No stats at all -> all nil, renderer shows dashes.
        let empty = IconInfo.make(stats: nil, peers: [])
        XCTAssertNil(empty.cpu)
        XCTAssertNil(empty.ram)
    }

    func testBadgeLetters() {
        XCTAssertEqual(IconInfo.badgeLetter(for: "barathans-5070"), "5")
        XCTAssertEqual(IconInfo.badgeLetter(for: "barathan\u{2019}s macbook"), "M")
        XCTAssertEqual(IconInfo.badgeLetter(for: "barathan's macbook"), "M")
        XCTAssertEqual(IconInfo.badgeLetter(for: "some-new-box"), "S")
    }

    func testHumanDuration() {
        XCTAssertEqual(humanDuration(59), "0m")
        XCTAssertEqual(humanDuration(3_660), "1h1m")
        XCTAssertEqual(humanDuration(90_000), "1d1h")
    }
}
