// Renders the dropdown from the v3 fixture to /tmp/tailmon-dropdown.png —
// a visual check of the design without opening the real menu.
import SwiftUI
import XCTest

@testable import Tailmon

final class SnapshotTests: XCTestCase {
    @MainActor
    func testRenderDropdown() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/fleet-v3", withExtension: "json"))
        let report = try tailmonJSONDecoder().decode(Report.self, from: Data(contentsOf: url))
        let model = FleetModel(preview: true)
        model.apply(report)
        try render(model, "/tmp/tailmon-dropdown.png")
    }

    @MainActor
    func testRenderLiveDropdown() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAILMON_LIVE"] == "1")
        let model = FleetModel(preview: true)
        // The installed app's registry, so offline fleet members show too.
        model.preloadAgents(UserDefaults(suiteName: "com.bosphorify.tailmon.menubar")?
            .stringArray(forKey: "agentHosts") ?? [])
        for i in 0..<2 { // two reports ~2s apart so the rates line has numbers
            if i > 0 { try await Task.sleep(nanoseconds: 2_100_000_000) }
            let (data, _) = try await URLSession.shared.data(from: FleetModel.fleetURL)
            model.apply(try tailmonJSONDecoder().decode(Report.self, from: data))
        }
        try render(model, "/tmp/tailmon-dropdown-live.png")
    }

    /// The live fleet as it draws on a screen with `TAILMON_ROOM` points of
    /// room (default: a 14" MacBook, 928), then the edit list, then the
    /// dropdown after one device was moved up and one hidden. PNGs go to
    /// `TAILMON_SNAPSHOT_DIR` (default /tmp).
    @MainActor
    func testRenderLiveArrangement() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["TAILMON_LIVE"] == "1")
        let dir = env["TAILMON_SNAPSHOT_DIR"] ?? "/tmp"
        let model = FleetModel(preview: true)
        model.preloadAgents(UserDefaults(suiteName: "com.bosphorify.tailmon.menubar")?
            .stringArray(forKey: "agentHosts") ?? [])
        for i in 0..<2 {
            if i > 0 { try await Task.sleep(nanoseconds: 2_100_000_000) }
            let (data, _) = try await URLSession.shared.data(from: FleetModel.fleetURL)
            model.apply(try tailmonJSONDecoder().decode(Report.self, from: data))
        }
        try render(model, "\(dir)/tailmon-all-open.png")

        model.setRoom(CGFloat(Double(env["TAILMON_ROOM"] ?? "") ?? 928))
        try render(model, "\(dir)/tailmon-fit.png")
        XCTAssertFalse(model.cardPlan.scrolls)

        model.editing = true
        try render(model, "\(dir)/tailmon-edit.png")

        let hosts = model.arrangedHosts
        if hosts.count >= 3 {
            model.move(hosts[hosts.count - 1], by: -1)
            model.toggleHidden(hosts[hosts.count - 2])
            try render(model, "\(dir)/tailmon-edit-changed.png")
            model.editing = false
            try render(model, "\(dir)/tailmon-fit-changed.png")
        }
    }

    /// The live fleet with a newer release pending: the dot on the ⋯.
    @MainActor
    func testRenderUpdateDot() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["TAILMON_LIVE"] == "1")
        let dir = env["TAILMON_SNAPSHOT_DIR"] ?? "/tmp"
        let model = FleetModel(preview: true)
        model.preloadAgents(UserDefaults(suiteName: "com.bosphorify.tailmon.menubar")?
            .stringArray(forKey: "agentHosts") ?? [])
        for i in 0..<2 {
            if i > 0 { try await Task.sleep(nanoseconds: 2_100_000_000) }
            let (data, _) = try await URLSession.shared.data(from: FleetModel.fleetURL)
            model.apply(try tailmonJSONDecoder().decode(Report.self, from: data))
        }
        model.setRoom(CGFloat(Double(env["TAILMON_ROOM"] ?? "") ?? 928))
        let page = try XCTUnwrap(URL(string: "https://github.com/barathanaslan/tailmon/releases"))
        model.setLatest(UpdateNotice(version: "9.9.9", page: page), current: "0.4.1")
        try render(model, "\(dir)/tailmon-update-dot.png")
    }

    @MainActor
    private func render(_ model: FleetModel, _ path: String) throws {
        let view = FleetView().environmentObject(model)
            .environment(\.snapshotMode, true)
            .background(Color(red: 0x26 / 255, green: 0x27 / 255, blue: 0x2b / 255))
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        let img = try XCTUnwrap(r.nsImage)
        let tiff = try XCTUnwrap(img.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(img.size.height, 200)
    }
}
