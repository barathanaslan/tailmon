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
