// The dropdown must stay on the screen: cards that do not fit shrink to one
// line from the bottom up, the user's order and pins are respected, and the
// height the plan works with is the height the views really draw.
import SwiftUI
import XCTest

@testable import Tailmon

final class LayoutTests: XCTestCase {
    func item(_ key: String, _ full: CGFloat?, pin: Bool? = nil) -> CardLayout.Item {
        CardLayout.Item(key: key, full: full, pin: pin)
    }

    func host(_ name: String, _ ip: String, _ status: String = "live") -> HostResult {
        HostResult(host: name, ip: ip, os: "linux", status: status, source: nil, error: nil, stats: nil)
    }

    // MARK: - CardLayout.plan

    func testEverythingOpenWhenItFits() {
        let plan = CardLayout.plan([item("a", 200), item("b", 200)], room: 408)
        XCTAssertEqual(plan.open, ["a", "b"])
        XCTAssertEqual(plan.height, 408)
        XCTAssertFalse(plan.scrolls)
    }

    func testLastCardsShrinkFirst() {
        // 200 + 8 + 200 + 8 + 31 + 8 + 31 = 486 fits 500; a third card would not.
        let items = [item("a", 200), item("b", 200), item("c", 200), item("d", 100)]
        let plan = CardLayout.plan(items, room: 500)
        XCTAssertEqual(plan.open, ["a", "b"])
        XCTAssertEqual(plan.height, 486)
        XCTAssertFalse(plan.scrolls)
        // Strictly from the first card that does not fit: d would fit instead
        // of c, but the user's order is the priority.
        XCTAssertFalse(plan.open.contains("d"))
    }

    func testPinsAreKept() {
        let items = [item("a", 200), item("b", 200, pin: false), item("c", 200), item("d", 200, pin: true)]
        // d is pinned open, b pinned closed: 200 + 31 + ? + 200 + 3 * 8.
        let plan = CardLayout.plan(items, room: 660)
        XCTAssertEqual(plan.open, ["a", "c", "d"])
        XCTAssertEqual(plan.height, 655)
        // Less room (a + d open is 486): c gives way, the pinned one stays.
        let tight = CardLayout.plan(items, room: 490)
        XCTAssertEqual(tight.open, ["a", "d"])
        XCTAssertFalse(tight.scrolls)
        // Less still: only the pinned card is open.
        XCTAssertEqual(CardLayout.plan(items, room: 480).open, ["d"])
    }

    func testScrollsOnlyWhenOneLineCardsDoNotFit() {
        let items = (0..<10).map { item("h\($0)", 200) }
        let plan = CardLayout.plan(items, room: 300) // ten lines need 382
        XCTAssertTrue(plan.open.isEmpty)
        XCTAssertEqual(plan.height, 382)
        XCTAssertTrue(plan.scrolls)
        // A pinned-open card that alone is too tall also scrolls rather than
        // being closed behind the user's back.
        let pinned = CardLayout.plan([item("a", 400, pin: true)], room: 300)
        XCTAssertEqual(pinned.open, ["a"])
        XCTAssertTrue(pinned.scrolls)
    }

    func testOfflineLinesCountButNeverOpen() {
        let plan = CardLayout.plan([item("a", 200), item("gone", nil), item("b", 200)], room: 1000)
        XCTAssertEqual(plan.open, ["a", "b"])
        XCTAssertEqual(plan.height, 200 + 31 + 200 + 16)
    }

    // MARK: - Arrangement

    func testOrderHiddenAndNewDevices() {
        let hosts = [host("mini", "1"), host("box", "2"), host("macbook", "3"), host("taha", "4")]
        var a = Arrangement()
        XCTAssertEqual(a.sorted(hosts).map(\.host), ["mini", "box", "macbook", "taha"]) // report order

        a.move("4", by: -1, among: hosts)
        XCTAssertEqual(a.sorted(hosts).map(\.host), ["mini", "box", "taha", "macbook"])
        a.move("1", by: -1, among: hosts) // already first: nothing moves
        XCTAssertEqual(a.sorted(hosts).map(\.host), ["mini", "box", "taha", "macbook"])
        a.move("1", by: 1, among: hosts)
        XCTAssertEqual(a.sorted(hosts).map(\.host), ["box", "mini", "taha", "macbook"])

        // A device that joins later goes to the end, whatever its name.
        let grown = hosts + [host("aaa-new", "5")]
        XCTAssertEqual(a.sorted(grown).map(\.host), ["box", "mini", "taha", "macbook", "aaa-new"])

        a.toggleHidden("2")
        XCTAssertEqual(a.shown(grown).map(\.host), ["mini", "taha", "macbook", "aaa-new"])
        XCTAssertEqual(a.sorted(grown).count, 5) // the edit list still has it
        a.toggleHidden("2")
        XCTAssertEqual(a.shown(grown).first?.host, "box")

        a.toggleHidden("4")
        a.pinned["4"] = false
        a.retain(["1", "2", "3"]) // taha left the fleet
        XCTAssertEqual(a.order, ["2", "1", "3"])
        XCTAssertTrue(a.hidden.isEmpty)
        XCTAssertTrue(a.pinned.isEmpty)
    }

    func testArrangementRoundTrips() throws {
        var a = Arrangement()
        a.order = ["2", "1"]
        a.hidden = ["3"]
        a.pinned = ["1": false]
        let d = try scratchDefaults()
        a.save(d)
        XCTAssertEqual(Arrangement.load(d), a)
    }

    // MARK: - The model: clicks, and the heights the plan relies on

    @MainActor
    func fixtureModel() throws -> FleetModel {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/fleet-v3", withExtension: "json"))
        let report = try tailmonJSONDecoder().decode(Report.self, from: Data(contentsOf: url))
        let model = FleetModel(preview: true)
        model.preloadAgents(report.hosts.map { HostKey.of($0) })
        model.apply(report)
        return model
    }

    @MainActor
    func renderedHeight(_ model: FleetModel) throws -> CGFloat {
        let view = FleetView().environmentObject(model)
            .environment(\.snapshotMode, true)
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        return try XCTUnwrap(r.nsImage).size.height
    }

    /// The dropdown's whole height as the model computes it.
    @MainActor
    func plannedHeight(_ model: FleetModel) -> CGFloat {
        10 + 16 + CardLayout.spacing + model.cardPlan.height + 10
    }

    @MainActor
    func testPlannedHeightIsTheRenderedHeight() throws {
        let model = try fixtureModel()
        // Everything open (three cards, one offline line).
        XCTAssertEqual(model.cardPlan.open.count, 3)
        XCTAssertEqual(try renderedHeight(model), plannedHeight(model), accuracy: 1)

        // Every processes list toggled.
        for h in model.shownHosts where model.isCard(h) { model.toggleExpanded(h) }
        XCTAssertEqual(try renderedHeight(model), plannedHeight(model), accuracy: 1)

        // Less room than that: the last cards are lines, and it fits.
        let full = plannedHeight(model)
        model.setRoom(full - 100)
        let plan = model.cardPlan
        XCTAssertLessThan(plan.open.count, 3)
        XCTAssertFalse(plan.scrolls)
        let drawn = try renderedHeight(model)
        XCTAssertEqual(drawn, plannedHeight(model), accuracy: 1)
        XCTAssertLessThanOrEqual(drawn, full - 100 + 1)

        // Room for nothing but lines.
        model.setRoom(FleetModel.minRoom)
        XCTAssertTrue(model.cardPlan.open.isEmpty)
        XCTAssertEqual(try renderedHeight(model), plannedHeight(model), accuracy: 1)
    }

    @MainActor
    func testHeaderClickKeepsTheWeakestPin() throws {
        let model = try fixtureModel()
        let cards = model.shownHosts.filter(model.isCard)
        let first = try XCTUnwrap(cards.first), last = try XCTUnwrap(cards.last)
        let key = HostKey.of(last)

        // Plenty of room: a click closes the card (pinned closed), the next
        // click makes it automatic again, not pinned open.
        model.toggleCard(last)
        XCTAssertFalse(model.cardPlan.open.contains(key))
        XCTAssertEqual(model.arrangement.pinned[key], false)
        model.toggleCard(last)
        XCTAssertTrue(model.cardPlan.open.contains(key))
        XCTAssertNil(model.arrangement.pinned[key])

        // Too little room: the last card is a line by itself. A click opens
        // it (pinned open), and an earlier automatic card gives way.
        model.setRoom(plannedHeight(model) - 60)
        XCTAssertFalse(model.cardPlan.open.contains(key))
        XCTAssertNil(model.arrangement.pinned[key])
        model.toggleCard(last)
        XCTAssertTrue(model.cardPlan.open.contains(key))
        XCTAssertEqual(model.arrangement.pinned[key], true)
        XCTAssertFalse(model.cardPlan.scrolls)
        // And back: one click, automatic again, a line again.
        model.toggleCard(last)
        XCTAssertFalse(model.cardPlan.open.contains(key))
        XCTAssertNil(model.arrangement.pinned[key])
        XCTAssertTrue(model.cardPlan.open.contains(HostKey.of(first)))
    }

    // MARK: - A real window

    /// The fleet with `count` live devices (the fixture's first card, cloned).
    @MainActor
    func bigModel(_ count: Int) throws -> FleetModel {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/fleet-v3", withExtension: "json"))
        var report = try tailmonJSONDecoder().decode(Report.self, from: Data(contentsOf: url))
        let card = try XCTUnwrap(report.hosts.first { $0.isLive && $0.stats != nil })
        report.hosts = (0..<count).map { i in
            var h = card
            h.host = "device-\(i)"
            h.ip = "100.64.9.\(i + 1)"
            h.source = i == 0 ? "local" : "agent"
            return h
        }
        let model = FleetModel(preview: true)
        model.apply(report)
        return model
    }

    /// The dropdown in a window the way MenuBarExtra hosts it: the fitter
    /// learns the room under the window's top edge, the content limits
    /// itself to it, and the window's bottom edge stays on the screen with
    /// the top edge where it was. Needs a screen (skipped without one); the
    /// window is fully transparent.
    @MainActor
    func fitInWindow(_ model: FleetModel) throws -> (window: NSRect, top: CGFloat, visible: NSRect) {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let top = visible.maxY - 6
        let window = NSPanel(
            contentRect: NSRect(x: visible.maxX - 360, y: top - 300, width: 340, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: FleetView().environmentObject(model))
        window.orderFrontRegardless()
        defer { window.close() }
        // Until the fitter has reported the room and the height has settled.
        var last = CGFloat(-1), settled = 0
        for _ in 0..<40 where settled < 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let h = window.frame.height
            settled = (model.room < 50_000 && h == last) ? settled + 1 : 0
            last = h
        }
        return (window.frame, top, visible)
    }

    @MainActor
    func testWindowStaysOnTheScreen() throws {
        try XCTSkipUnless(NSScreen.main != nil, "no screen")
        // Eight cards: taller than the screen when all open, so the last ones are lines.
        let some = try bigModel(8)
        let a = try fitInWindow(some)
        let room = a.top - a.visible.minY - 8
        XCTAssertEqual(some.room, room, accuracy: 1, "the fitter reports the room under the window")
        XCTAssertEqual(a.window.maxY, a.top, accuracy: 1, "top edge stays put")
        XCTAssertGreaterThanOrEqual(a.window.minY, a.visible.minY + 7, "bottom edge is on the screen")
        let plan = some.cardPlan
        XCTAssertFalse(plan.scrolls)
        XCTAssertLessThan(plan.open.count, 8)
        XCTAssertGreaterThan(plan.open.count, 0)
        XCTAssertEqual(a.window.height, 10 + 16 + CardLayout.spacing + plan.height + 10, accuracy: 1)

        // Sixty devices: even as lines they do not fit, so the list scrolls
        // and the window is exactly as tall as the room.
        let many = try bigModel(60)
        let b = try fitInWindow(many)
        XCTAssertTrue(many.cardPlan.scrolls)
        XCTAssertEqual(b.window.height, many.room, accuracy: 1)
        XCTAssertGreaterThanOrEqual(b.window.minY, b.visible.minY + 7)
        XCTAssertEqual(b.window.maxY, b.top, accuracy: 1)
    }

    @MainActor
    func testHiddenAndOrderInTheModel() throws {
        let model = try fixtureModel()
        let names = model.shownHosts.map(\.host)
        let second = model.shownHosts[1]
        model.move(second, by: -1)
        XCTAssertEqual(model.shownHosts.first?.host, second.host)
        model.toggleHidden(second)
        XCTAssertFalse(model.shownHosts.contains { $0.host == second.host })
        XCTAssertEqual(model.hiddenCount, 1)
        XCTAssertEqual(model.arrangedHosts.count, names.count) // still in the edit list
        // Editing mode draws (snapshot) without the hidden device being lost.
        model.editing = true
        XCTAssertGreaterThan(try renderedHeight(model), 100)
    }
}
