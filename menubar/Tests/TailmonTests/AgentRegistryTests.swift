// A node that never answered with an agent is not part of the fleet: it must
// not show as "offline" or "no agent". Nodes that once ran one keep showing.
import XCTest

@testable import Tailmon

final class AgentRegistryTests: XCTestCase {
    func host(_ name: String, _ ip: String, _ status: String, local: Bool = false) -> HostResult {
        HostResult(host: name, ip: ip, os: "linux", status: status,
                   source: local ? "local" : nil, error: nil, stats: nil)
    }

    func testNeverSeenAgentIsHidden() {
        var reg = AgentRegistry()
        let first = [
            host("mini", "100.0.0.1", "offline", local: true),
            host("box", "100.0.0.2", "live"),
            host("stranger", "100.0.0.3", "no-agent"),
            host("phone", "100.0.0.4", "offline"),
        ]
        XCTAssertTrue(reg.record(first))
        XCTAssertEqual(reg.visible(first).map(\.host), ["mini", "box"])

        // The box drops off later: it was seen live once, so it stays visible.
        let later = [host("box", "100.0.0.2", "offline"), host("stranger", "100.0.0.3", "no-agent")]
        XCTAssertFalse(reg.record(later))
        XCTAssertEqual(reg.visible(later).map(\.host), ["box"])
    }

    func testKeyedByIPNotName() {
        var reg = AgentRegistry()
        reg.recordLive(host: "old-name", ip: "100.0.0.2")
        XCTAssertTrue(reg.contains(host: "renamed", ip: "100.0.0.2"))
        XCTAssertFalse(reg.contains(host: "old-name", ip: "100.0.0.9"))
    }
}
