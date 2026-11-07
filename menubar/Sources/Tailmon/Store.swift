// Small bounded per-host memory: the last reading of every disk, when each
// host was last live, and ONE previous counter snapshot per host for rates.
// No history buffers (owner rule since the v1 leak incident).
import Foundation

struct HostMemory: Codable, Equatable {
    struct KnownDisk: Codable, Equatable {
        var disk: Stats.Disk
        var seen: Date
    }

    /// host key -> mount -> last reading
    var disks: [String: [String: KnownDisk]] = [:]

    static let diskRetention: TimeInterval = 30 * 86_400

    /// Records a live host's disks. Removable media (USB sticks, cards) are
    /// not remembered: they come and go by design.
    mutating func recordLive(host: String, disks live: [Stats.Disk], now: Date = Date()) {
        var known = disks[host] ?? [:]
        // Agent-reported stale disks are old readings: never refresh them here.
        for d in live where d.kind != "removable" && d.stale != true {
            known[Self.mountKey(d.mount)] = KnownDisk(disk: d, seen: now)
        }
        // A disk that came back as removable must not linger from an older reading.
        for d in live where d.kind == "removable" { known[Self.mountKey(d.mount)] = nil }
        disks[host] = known.isEmpty ? nil : known
    }

    /// Live disks plus every remembered disk the host did not report this
    /// time (asleep / disabled drive), shown with its last reading in the same
    /// style. Root first, then by mount.
    func merged(host: String, live: [Stats.Disk]) -> [Stats.Disk] {
        var out = live
        // A remembered disk shows only when no live (or agent-stale) volume
        // has the same normalized mount: "C:" (0.2.0 agents) == "C:\\" == "c:\\".
        var shown = Set(live.map { Self.mountKey($0.mount) })
        for (key, k) in disks[host] ?? [:] where !shown.contains(key) {
            shown.insert(key)
            out.append(k.disk)
        }
        return out.sorted { a, b in
            if a.mount == "/" { return b.mount != "/" }
            if b.mount == "/" { return false }
            return a.mount.localizedStandardCompare(b.mount) == .orderedAscending
        }
    }

    /// Volume identity: Windows drive letters case-insensitive with or
    /// without the trailing backslash ("C:", "C:\\", "c:\\" -> "C:"); other
    /// mounts without a trailing slash ("/" stays "/").
    static func mountKey(_ m: String) -> String {
        var k = m
        while k.count > 1, k.hasSuffix("/") || k.hasSuffix("\\") { k.removeLast() }
        if k.count == 2, k.hasSuffix(":"), let c = k.first, c.isLetter { return k.uppercased() }
        return k
    }

    /// Re-keys entries saved before keys were normalized, keeping the most
    /// recent reading per volume. Run once on load.
    mutating func normalizeKeys() {
        for (host, known) in disks {
            var fixed: [String: KnownDisk] = [:]
            for (mount, k) in known {
                let key = Self.mountKey(mount)
                if let have = fixed[key], have.seen >= k.seen { continue }
                fixed[key] = k
            }
            disks[host] = fixed
        }
    }

    /// Drops disks unseen for 30 days.
    mutating func prune(now: Date = Date()) {
        for (host, known) in disks {
            let kept = known.filter { now.timeIntervalSince($0.value.seen) <= Self.diskRetention }
            disks[host] = kept.isEmpty ? nil : kept
        }
    }

    // Persistence (UserDefaults, a few KB at most).
    private static let key = "hostMemory.v1"

    static func load(_ d: UserDefaults = .standard) -> HostMemory {
        guard let data = d.data(forKey: key),
              let m = try? JSONDecoder().decode(HostMemory.self, from: data)
        else { return HostMemory() }
        return m
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

struct Rates: Equatable {
    var netRx: Double
    var netTx: Double
    var diskRead: Double?
    var diskWrite: Double?
}

/// One previous counter snapshot per host -> bytes/s. A repeated snapshot
/// (same sampled_at, served from the agent's 1s cache) keeps the last rate.
struct RateTracker {
    private struct Snap {
        var at: Date
        var rx, tx: UInt64
        var r, w: UInt64?
    }

    private var prev: [String: Snap] = [:]
    private(set) var rates: [String: Rates] = [:]

    mutating func update(host: String, stats: Stats) {
        guard let net = stats.net, let at = stats.sampledDate else { return }
        let snap = Snap(at: at, rx: net.rxBytes, tx: net.txBytes,
                        r: stats.diskIo?.readBytes, w: stats.diskIo?.writeBytes)
        defer { prev[host] = snap }
        guard let p = prev[host] else { return }
        let dt = at.timeIntervalSince(p.at)
        guard dt > 0.2 else { return } // same cached sample: keep the last rate
        func rate(_ now: UInt64?, _ before: UInt64?) -> Double? {
            guard let now, let before else { return nil }
            return now >= before ? Double(now - before) / dt : 0 // counter reset
        }
        rates[host] = Rates(
            netRx: rate(snap.rx, p.rx) ?? 0, netTx: rate(snap.tx, p.tx) ?? 0,
            diskRead: rate(snap.r, p.r), diskWrite: rate(snap.w, p.w))
    }

    /// Forget hosts no longer in the fleet (bounded state).
    mutating func retain(hosts: Set<String>) {
        prev = prev.filter { hosts.contains($0.key) }
        rates = rates.filter { hosts.contains($0.key) }
    }
}
