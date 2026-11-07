// Opt-in (TAILMON_LIVE=1): renders the real FleetView with live data from the
// local agent's /fleet in an offscreen AppKit window and checks that toggling the processes
// disclosure resizes the window within the same layout pass, keeping the
// top edge fixed (the flicker fix).
import SwiftUI
import XCTest

@testable import Tailmon

final class LiveWindowTests: XCTestCase {
    @MainActor
    func testLiveWindow() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TAILMON_LIVE"] == "1")
        let (data, _) = try await URLSession.shared.data(from: FleetModel.fleetURL)
        let report = try tailmonJSONDecoder().decode(Report.self, from: data)
        let model = FleetModel(preview: true)
        model.apply(report)
        // Two reports ~2s apart so the rates line has numbers.
        try await Task.sleep(nanoseconds: 2_100_000_000)
        let (data2, _) = try await URLSession.shared.data(from: FleetModel.fleetURL)
        model.apply(try tailmonJSONDecoder().decode(Report.self, from: data2))

        let host = NSHostingView(rootView: FleetView().environmentObject(model)
            .environment(\.colorScheme, .dark))
        host.sizingOptions = [] // the window size is the fitter's job here
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0x26 / 255, green: 0x27 / 255, blue: 0x2b / 255, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await settle(host)

        let top = window.frame.maxY
        let expanded = window.frame.height
        XCTAssertGreaterThan(expanded, 300, "window should have grown to the content")
        try write(host, "/tmp/tailmon-window-expanded.png")

        // Collapse the local host's processes: the window must shrink in the
        // same pass, top edge unchanged.
        let local = try XCTUnwrap(model.hosts.first { $0.source == "local" })
        XCTAssertTrue(model.isExpanded(local))
        model.toggleExpanded(local)
        await settle(host)
        XCTAssertLessThan(window.frame.height, expanded - 50)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
        try write(host, "/tmp/tailmon-window-collapsed.png")

        model.toggleExpanded(local)
        await settle(host)
        XCTAssertEqual(window.frame.height, expanded, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
    }

    @MainActor
    private func settle(_ host: NSView) async {
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    private func write(_ view: NSView, _ path: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
