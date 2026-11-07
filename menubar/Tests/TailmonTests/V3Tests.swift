// v0.3.0: new agent fields, formatting, last-known disks, rates, native
// label math, and the fleet model's apply() path.
import XCTest

@testable import Tailmon

final class V3Tests: XCTestCase {
    func fixture(_ name: String) throws -> Report {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        return try tailmonJSONDecoder().decode(Report.self, from: Data(contentsOf: url))
    }

    func testDecodeV3Fields() throws {
        let r = try fixture("fleet-v3")
        let mini = try XCTUnwrap(r.hosts.first { $0.source == "local" }?.stats)
        let mg = try XCTUnwrap(mini.gpu?.first)
        XCTAssertEqual(mg.unified, true)
        XCTAssertNotNil(mg.vramUsedMb)
        XCTAssertNil(mg.vramTotalMb)
        XCTAssertNotNil(mini.diskIo)
        XCTAssertNotNil(mini.sampledDate)
        let root = try XCTUnwrap(mini.disks?.first)
        XCTAssertEqual(root.label, "HD")
        XCTAssertEqual(root.kind, "internal")

        let win = try XCTUnwrap(r.hosts.first { $0.host == "barathans-5090" }?.stats)
        let g = try XCTUnwrap(win.gpu?.first)
        XCTAssertEqual(g.powerW, 548.3)
        XCTAssertEqual(g.fanPct, 62)
        XCTAssertNil(win.cpu.load1)
    }

    func testOldAgentStillDecodes() throws {
        // v0.2.0 output (the fixture predates every 0.3.0 field).
        let r = try fixture("fleet")
        let d = try XCTUnwrap(r.hosts.first?.stats?.disks?.first)
        XCTAssertNil(d.label)
        XCTAssertEqual(d.used, d.totalGb - d.freeGb, accuracy: 0.01)
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.pct(14.2), "14%")
        XCTAssertEqual(Fmt.pct(9.6), "9.6%")
        XCTAssertEqual(Fmt.pct(0.2), "0.2%")
        XCTAssertEqual(Fmt.pct(0), "0%")
        // Relayed old-agent disk: used_gb 0 is not "empty".
        XCTAssertEqual(Stats.Disk(mount: "/", freeGb: 327.7, totalGb: 914.8, usedGb: 0).used, 587.1, accuracy: 0.01)
        XCTAssertEqual(Fmt.memPair(usedMb: 19354, totalMb: 32768), "18.9 / 32 G")
        XCTAssertEqual(Fmt.memPair(usedMb: 29081, totalMb: 32607), "28.4 / 32 G")
        XCTAssertEqual(Fmt.diskPair(used: 372, total: 494), "372 / 494 G")
        XCTAssertEqual(Fmt.diskPair(used: 1264.7, total: 1862.9), "1.2 / 1.8 T")
        XCTAssertEqual(Fmt.diskFree(122.4), "122 G boş")
        XCTAssertEqual(Fmt.diskFree(16793), "16.4 T boş")
        XCTAssertEqual(Fmt.procMem(149), "149 M")
        XCTAssertEqual(Fmt.procMem(11468.8), "11.2 G")
        XCTAssertEqual(Fmt.rate(6 * 1024), "6.00 KB/s")
        XCTAssertEqual(Fmt.rate(84 * 1024), "84.0 KB/s")
        XCTAssertEqual(Fmt.rate(880 * 1024), "880 KB/s")
        XCTAssertEqual(Fmt.rate(999.7 * 1024), "0.98 MB/s")
        XCTAssertEqual(Fmt.rate(1.2 * 1024 * 1024), "1.20 MB/s")
        XCTAssertEqual(Fmt.rate(210 * 1024 * 1024), "210 MB/s")
        XCTAssertEqual(Fmt.rate(0), "0 KB/s")
        XCTAssertLessThanOrEqual(Fmt.rate(88.8 * 1024 * 1024).count, 9)
        XCTAssertEqual(Fmt.age(2), "2 sn önce")
    }

    func testVersionNamedProcess() {
        func proc(_ name: String, _ cmd: String?) -> Stats.Proc {
            Stats.Proc(pid: 1, name: name, cpuPct: 1, memMb: 1, command: cmd)
        }
        XCTAssertEqual(Fmt.procName(proc("2.1.318", "/Users/x/.local/share/claude/versions/2.1.318 --print --sdk-url h…")), "claude")
        XCTAssertEqual(Fmt.procName(proc("0.167.0", "/opt/tool/releases/0.167.0/bin/0.167.0 x")), "tool")
        XCTAssertEqual(Fmt.procName(proc("Claude Helper", "/Applications/Claude.app/x")), "Claude Helper")
        XCTAssertEqual(Fmt.procName(proc("2.1.318", nil)), "2.1.318")
        XCTAssertFalse(Fmt.isVersion("python3.13"))
        XCTAssertTrue(Fmt.isVersion("3.13"))
    }

    func testDiskTags() {
        let c = Stats.Disk(mount: "C:\\", freeGb: 598, totalGb: 1862, label: "Windows", fstype: "ntfs", kind: "internal")
        XCTAssertEqual(Fmt.diskTag(c), "C")
        XCTAssertNil(Fmt.diskName(c))
        XCTAssertEqual(Fmt.diskTooltip(c), "C: Windows · dahili · ntfs · 598 G boş")
        let hd = Stats.Disk(mount: "/", freeGb: 110, totalGb: 460, label: "HD", fstype: "apfs", kind: "internal")
        XCTAssertEqual(Fmt.diskTag(hd), "Disk")
        XCTAssertNil(Fmt.diskName(hd))
        XCTAssertEqual(Fmt.diskTooltip(hd), "sistem diski · dahili · apfs · 110 G boş")
        let linuxRoot = Stats.Disk(mount: "/", freeGb: 1, totalGb: 2, fstype: "ext4")
        XCTAssertEqual(Fmt.diskTag(linuxRoot), "Disk")
        XCTAssertNil(Fmt.diskName(linuxRoot))
        let ext = Stats.Disk(mount: "/Volumes/Elements", freeGb: 1, totalGb: 2, label: "Elements", kind: "external")
        XCTAssertEqual(Fmt.diskTag(ext), "Disk")
        XCTAssertEqual(Fmt.diskName(ext), "Elements")
        let data = Stats.Disk(mount: "/mnt/data", freeGb: 1, totalGb: 2)
        XCTAssertEqual(Fmt.diskName(data), "data")
    }

    // The box's D: (a WD drive that sleeps or is disabled) disappears from a
    // live report: it must still show, with its last reading.
    func testLastKnownDisks() {
        var m = HostMemory()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let c = Stats.Disk(mount: "C:\\", freeGb: 600, totalGb: 1862, kind: "internal")
        let d = Stats.Disk(mount: "D:\\", freeGb: 16793, totalGb: 18627, label: "Elements", kind: "external")
        let usb = Stats.Disk(mount: "F:\\", freeGb: 3, totalGb: 32, kind: "removable")
        m.recordLive(host: "box", disks: [c, d, usb], now: t0)

        let merged = m.merged(host: "box", live: [c])
        XCTAssertEqual(merged.map(\.mount), ["C:\\", "D:\\"]) // removable not remembered
        XCTAssertEqual(merged[1], d)

        // An agent-side stale D: (0.3.0 agents remember it themselves) does
        // not refresh the app's own reading.
        var staleD = d
        staleD.freeGb = 1
        staleD.stale = true
        var m2 = m
        m2.recordLive(host: "box", disks: [c, staleD], now: t0.addingTimeInterval(60))
        XCTAssertEqual(m2.disks["box"]?["D:"]?.disk, d)
        XCTAssertEqual(m2.merged(host: "box", live: [c, staleD]).map(\.mount), ["C:\\", "D:\\"])

        // Encodes/decodes for UserDefaults.
        let data = try! JSONEncoder().encode(m)
        XCTAssertEqual(try! JSONDecoder().decode(HostMemory.self, from: data), m)

        // Pruned after 30 days unseen; the live disk was refreshed.
        m.recordLive(host: "box", disks: [c], now: t0.addingTimeInterval(31 * 86_400))
        m.prune(now: t0.addingTimeInterval(31 * 86_400))
        XCTAssertEqual(m.merged(host: "box", live: []).map(\.mount), ["C:\\"])
    }

    // 0.2.0 agents reported Windows drives as "C:", 0.3.0 as "C:\\": the old
    // cache entries must not show as a second C / E.
    func testMountKeysNormalized() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var m = HostMemory()
        m.disks["box"] = [
            "C:": .init(disk: Stats.Disk(mount: "C:", freeGb: 1, totalGb: 2), seen: t0),
            "E:": .init(disk: Stats.Disk(mount: "E:", freeGb: 1, totalGb: 2), seen: t0),
            "/Volumes/X/": .init(disk: Stats.Disk(mount: "/Volumes/X/", freeGb: 1, totalGb: 2), seen: t0),
        ]
        m.normalizeKeys()
        let live = [Stats.Disk(mount: "C:\\", freeGb: 1, totalGb: 2), Stats.Disk(mount: "e:\\", freeGb: 1, totalGb: 2),
                    Stats.Disk(mount: "D:\\", freeGb: 1, totalGb: 2, stale: true)]
        XCTAssertEqual(m.merged(host: "box", live: live).map(\.mount), ["C:\\", "D:\\", "e:\\", "/Volumes/X/"].sorted {
            $0.localizedStandardCompare($1) == .orderedAscending })
        m.recordLive(host: "box", disks: live, now: t0.addingTimeInterval(1))
        XCTAssertEqual(Set(m.disks["box"]!.keys), ["C:", "E:", "/Volumes/X"])
        XCTAssertEqual(HostMemory.mountKey("/"), "/")
        XCTAssertEqual(HostMemory.mountKey("c:\\"), "C:")
    }

    func testMergedOrderRootFirst() {
        let m = HostMemory()
        let disks = [
            Stats.Disk(mount: "/Volumes/B", freeGb: 1, totalGb: 2),
            Stats.Disk(mount: "/", freeGb: 1, totalGb: 2),
            Stats.Disk(mount: "/Volumes/A", freeGb: 1, totalGb: 2),
        ]
        XCTAssertEqual(m.merged(host: "x", live: disks).map(\.mount), ["/", "/Volumes/A", "/Volumes/B"])
    }

    func testRates() throws {
        let r = try fixture("fleet-v3")
        var s = try XCTUnwrap(r.hosts[0].stats)
        var tracker = RateTracker()
        tracker.update(host: "h", stats: s)
        XCTAssertNil(tracker.rates["h"]) // one reading: no rate yet

        // Same cached sample served again: still no rate, no division by zero.
        tracker.update(host: "h", stats: s)
        XCTAssertNil(tracker.rates["h"])

        let t = try XCTUnwrap(s.sampledDate).addingTimeInterval(2)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        s.sampledAt = f.string(from: t)
        s.net = Stats.Net(rxBytes: s.net!.rxBytes + 2_000_000, txBytes: s.net!.txBytes + 200_000)
        s.diskIo = Stats.DiskIO(readBytes: s.diskIo!.readBytes + 8_000_000, writeBytes: s.diskIo!.writeBytes)
        tracker.update(host: "h", stats: s)
        let rate = try XCTUnwrap(tracker.rates["h"])
        XCTAssertEqual(rate.netRx, 1_000_000, accuracy: 1_000)
        XCTAssertEqual(rate.diskWrite ?? -1, 0)

        tracker.retain(hosts: [])
        XCTAssertTrue(tracker.rates.isEmpty)
    }

    func testNativeLabelMath() {
        // user, system, idle, nice
        XCTAssertEqual(LocalSampler.busyPercent(prev: [100, 100, 800, 0], now: [130, 120, 850, 0]) ?? -1, 50, accuracy: 0.01)
        // Counter wrap.
        XCTAssertEqual(LocalSampler.busyPercent(prev: [UInt32.max - 9, 0, 0, 0], now: [10, 0, 20, 0]) ?? -1, 50, accuracy: 0.01)
        XCTAssertNil(LocalSampler.busyPercent(prev: [1, 1, 1, 1], now: [1, 1, 1, 1]))
        XCTAssertEqual(LocalSampler.usedPercent(total: 1000 * 16384, freePages: 200, inactivePages: 50, pageSize: 16384), 75, accuracy: 0.01)
        XCTAssertEqual(LocalSampler.pressure(freePct: 75), "normal")
        XCTAssertEqual(LocalSampler.pressure(freePct: 15), "warn")
        XCTAssertEqual(LocalSampler.pressure(freePct: 5), "critical")
    }

    func testLiveLocalSampler() {
        let s = LocalSampler()
        _ = s.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let v = s.sample()
        let cpu = try? XCTUnwrap(v.cpuPct)
        XCTAssertNotNil(cpu)
        XCTAssertGreaterThan(v.ramPct ?? 0, 1)
        XCTAssertNotNil(v.pressure)
    }

    func testFleetErrorMessages() {
        XCTAssertTrue(FleetModel.describe(FleetError.status(404)).contains("/fleet yok"))
        XCTAssertTrue(FleetModel.describe(URLError(.cannotConnectToHost)).contains("çalışmıyor"))
    }
}
