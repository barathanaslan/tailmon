// FleetModel drives the whole app. Efficiency contract (owner requirement):
//
// Menu CLOSED: the label is read natively every 5s (a few Mach/sysctl calls
// and one IORegistry read — LocalSampler), and known peers get a tiny /health
// probe every 60s for their letters. Zero subprocesses, zero HTTP to the
// local agent, zero process scans.
//
// Menu OPEN: one GET http://127.0.0.1:7020/fleet?top=10 every 2s, at most one
// in flight. The local agent fans out to the tailnet and caches for 1s.
//
// No history: latest report, one previous counter snapshot per host (rates)
// and a small persisted last-known disk map (HostMemory).
//
// NO power controls anywhere in this app — owner rule (2026-07-10).
import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class FleetModel: ObservableObject {
    @Published var iconImage: NSImage?
    @Published private(set) var report: Report?
    /// Hosts to show: report.hosts minus nodes that never ran an agent.
    @Published private(set) var hosts: [HostResult] = []
    @Published private(set) var fleetError: String?
    @Published private(set) var receivedAt: Date?
    @Published private(set) var rates: [String: Rates] = [:]
    @Published private(set) var memory = HostMemory()
    /// Per-host override of the processes disclosure (default: open only for
    /// the local host). Kept here so it survives refreshes and menu reopen.
    @Published private(set) var procsExpanded: [String: Bool] = [:]
    @Published private(set) var loginItemEnabled = false
    @Published var menuOpen = false {
        didSet { if menuOpen != oldValue { menuOpenChanged() } }
    }

    private var labelTimer: Timer?
    private var probeTimer: Timer?
    private var fleetTimer: Timer?
    private var fleetTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private let sampler = LocalSampler()
    private var lastLocal = LocalSample()
    private var lastIconInfo: IconInfo?
    private let probeSession: URLSession
    private let fleetSession: URLSession
    private let log = CappedLog(name: "tailmon-menubar")
    private var rateTracker = RateTracker()

    // Peers learned from the last successful fleet fetch, persisted so the
    // label can show device status from the very first (menu-closed) tick.
    private var knownPeers: [(name: String, ip: String)] = []
    private var peerStatuses: [String: PeerBadge.Status] = [:]
    private var agents = AgentRegistry()

    static let labelInterval: TimeInterval = 5
    static let probeInterval: TimeInterval = 60
    static let fleetInterval: TimeInterval = 2
    static let fleetURL = URL(string: "http://127.0.0.1:7020/fleet?top=10")!
    private static let peersKey = "knownPeers"
    private static let agentsKey = "agentHosts"
    private static let autoLoginKey = "didAutoRegisterLoginItem"

    /// preview: no timers, no network, no login-item side effects (tests and
    /// snapshot rendering).
    init(preview: Bool = false) {
        let probe = URLSessionConfiguration.ephemeral
        probe.timeoutIntervalForRequest = 2
        probe.timeoutIntervalForResource = 3
        probe.httpMaximumConnectionsPerHost = 1
        probeSession = URLSession(configuration: probe)
        // A cold fleet report can take ~0.6s (local sample) + up to 2.5s (a
        // slow peer); the agent bounds the whole report at 8s.
        let fleet = URLSessionConfiguration.ephemeral
        fleet.timeoutIntervalForRequest = 9
        fleet.timeoutIntervalForResource = 10
        fleet.httpMaximumConnectionsPerHost = 1
        fleetSession = URLSession(configuration: fleet)
        if preview { return }

        loadPeers()
        agents = AgentRegistry(
            keys: Set(UserDefaults.standard.stringArray(forKey: Self.agentsKey) ?? []))
        memory = HostMemory.load()
        memory.prune()
        registerLoginItemOnce()
        refreshLoginItemState()
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        log.line("launch \(v ?? "?")")

        _ = sampler.sample() // prime CPU tick deltas
        labelTimer = makeTimer(Self.labelInterval) { $0.refreshLabel() }
        probeTimer = makeTimer(Self.probeInterval) { $0.probePeers() }
        // First real label after 1s (CPU% needs two tick readings), then one
        // probe so the letters are colored right away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshLabel()
            self?.probePeers()
        }
    }

    private func makeTimer(_ interval: TimeInterval, _ body: @escaping @MainActor (FleetModel) -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { body(self) }
            }
        }
        t.tolerance = interval * 0.1 // let the system coalesce wakeups
        RunLoop.main.add(t, forMode: .common) // keep ticking while menus track
        return t
    }

    private func menuOpenChanged() {
        fleetTimer?.invalidate()
        fleetTimer = nil
        if menuOpen {
            refreshLoginItemState()
            refreshFleet()
            fleetTimer = makeTimer(Self.fleetInterval) { $0.refreshFleet() }
        } else {
            // Nobody is looking: drop an in-flight request.
            fleetTask?.cancel()
            fleetTask = nil
        }
    }

    // MARK: - Login item

    // Launch at login is the DEFAULT (owner: the fleet contains machines that
    // boot unattended — monitoring must survive reboots). Registered once; a
    // later opt-out (menu toggle or System Settings) is never re-forced.
    private func registerLoginItemOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.autoLoginKey) else { return }
        d.set(true, forKey: Self.autoLoginKey)
        do {
            try SMAppService.mainApp.register()
            log.line("registered as login item (first-launch default)")
        } catch {
            log.line("login item registration failed: \(error.localizedDescription)")
        }
    }

    private func refreshLoginItemState() {
        loginItemEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.line("login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refreshLoginItemState()
    }

    func showLog() {
        NSWorkspace.shared.open(log.url)
    }

    // MARK: - Label (native local numbers + peer letters)

    private func refreshLabel() {
        let s = sampler.sample()
        lastLocal = LocalSample(
            cpuPct: s.cpuPct ?? lastLocal.cpuPct, // keep the last good CPU reading
            ramPct: s.ramPct, pressure: s.pressure, gpuPct: s.gpuPct)
        renderIcon()
    }

    private func renderIcon() {
        let info = IconInfo.make(local: lastLocal, peers: currentBadges())
        // Unchanged label: no new image, no menu bar redraw.
        guard info != lastIconInfo || iconImage == nil else { return }
        lastIconInfo = info
        iconImage = IconRenderer.render(info)
    }

    // MARK: - Peer probes (menu closed; letters only)

    private func probePeers() {
        // While the menu is open the fleet report carries the statuses.
        guard !menuOpen, probeTask == nil, !knownPeers.isEmpty else { return }
        let peers = knownPeers
        let session = probeSession
        probeTask = Task { [weak self] in
            let results = await withTaskGroup(of: (String, PeerBadge.Status).self) { group in
                for peer in peers {
                    group.addTask { (peer.name, await FleetModel.probe(session, ip: peer.ip)) }
                }
                var out: [(String, PeerBadge.Status)] = []
                for await r in group { out.append(r) }
                return out
            }
            guard let self else { return }
            self.probeTask = nil
            for (name, status) in results { self.peerStatuses[name] = status }
            var learned = false
            for peer in peers where self.peerStatuses[peer.name] == .live {
                learned = self.agents.recordLive(host: peer.name, ip: peer.ip) || learned
            }
            if learned { self.saveAgents() }
            self.renderIcon()
        }
    }

    nonisolated private static func probe(_ session: URLSession, ip: String) async -> PeerBadge.Status {
        guard let url = URL(string: "http://\(ip):7020/health") else { return .unknown }
        do {
            let (_, resp) = try await session.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200 ? .live : .noAgent
        } catch let e as URLError where e.code == .timedOut {
            return .offline // tailscale blackholes offline IPs
        } catch {
            return .noAgent // reachable, port closed
        }
    }

    private func saveAgents() {
        UserDefaults.standard.set(agents.keys.sorted(), forKey: Self.agentsKey)
    }

    // Every peer is still probed (that is how a freshly installed agent gets
    // noticed), but only nodes that have run an agent get a letter.
    private func currentBadges() -> [PeerBadge] {
        knownPeers.filter { agents.contains(host: $0.name, ip: $0.ip) }.map {
            PeerBadge(
                letter: IconInfo.badgeLetter(for: $0.name),
                status: peerStatuses[$0.name] ?? .unknown)
        }
    }

    private func loadPeers() {
        let stored = UserDefaults.standard.array(forKey: Self.peersKey) as? [[String: String]] ?? []
        knownPeers = stored.compactMap { d in
            guard let n = d["name"], let ip = d["ip"], !ip.isEmpty else { return nil }
            return (n, ip)
        }.sorted { $0.name < $1.name }
    }

    private func updatePeers(from report: Report) {
        // A degraded report (tailscale CLI failed -> local only) must not
        // wipe the known peer list.
        guard report.note == nil else { return }
        knownPeers = report.hosts
            .filter { $0.source != "local" }
            .compactMap { h -> (name: String, ip: String)? in
                guard let ip = h.ip, !ip.isEmpty else { return nil }
                return (h.host, ip)
            }
            .sorted { $0.name < $1.name }
        let names = Set(knownPeers.map(\.name))
        peerStatuses = peerStatuses.filter { names.contains($0.key) } // bounded
        for h in report.hosts where h.source != "local" {
            switch h.status {
            case "live": peerStatuses[h.host] = .live
            case "offline": peerStatuses[h.host] = .offline
            default: peerStatuses[h.host] = .noAgent
            }
        }
        UserDefaults.standard.set(
            knownPeers.map { ["name": $0.name, "ip": $0.ip] }, forKey: Self.peersKey)
    }

    // MARK: - Fleet (menu open only)

    private func refreshFleet() {
        guard menuOpen, fleetTask == nil else { return }
        let session = fleetSession
        fleetTask = Task { [weak self] in
            let result = await FleetModel.fetchFleet(session)
            guard let self, !Task.isCancelled else { return }
            self.fleetTask = nil
            switch result {
            case .success(let r):
                self.apply(r)
            case .failure(let e):
                let msg = FleetModel.describe(e)
                if self.fleetError != msg { self.log.line("fleet fetch failed: \(e)") }
                self.fleetError = msg
            }
        }
    }

    /// Applies one fleet report (internal for tests).
    func apply(_ r: Report, now: Date = Date()) {
        report = r
        receivedAt = now
        fleetError = nil
        if agents.record(r.hosts) { saveAgents() }
        updatePeers(from: r)

        let visible = agents.visible(r.hosts)
        var mem = memory
        var keys = Set<String>()
        for h in visible {
            let key = HostKey.of(h)
            keys.insert(key)
            if h.isLive, let s = h.stats {
                mem.recordLive(host: key, disks: s.disks ?? [], now: now)
                rateTracker.update(host: key, stats: s)
            }
        }
        rateTracker.retain(hosts: keys)
        if mem != memory {
            memory = mem
            memory.save()
        }
        if rates != rateTracker.rates { rates = rateTracker.rates }
        hosts = visible
        renderIcon()
    }

    nonisolated private static func fetchFleet(_ session: URLSession) async -> Result<Report, Error> {
        do {
            let (data, resp) = try await session.data(from: fleetURL)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw FleetError.status(http.statusCode)
            }
            return .success(try tailmonJSONDecoder().decode(Report.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func describe(_ e: Error) -> String {
        if case FleetError.status(let code) = e {
            return code == 404
                ? "Yerel tailmon ajanı eski (/fleet yok) — v0.3.0 ajanını kurun."
                : "Yerel tailmon ajanı hata döndürdü (HTTP \(code))."
        }
        if let u = e as? URLError {
            switch u.code {
            case .cannotConnectToHost, .networkConnectionLost:
                return "Yerel tailmon ajanı çalışmıyor (127.0.0.1:7020)."
            case .timedOut:
                return "Yerel tailmon ajanı yanıt vermedi."
            default: break
            }
        }
        if e is DecodingError { return "Ajan yanıtı okunamadı (sürüm uyuşmuyor olabilir)." }
        return "Filo bilgisi alınamadı: \(e.localizedDescription)"
    }

    // MARK: - View helpers

    func isExpanded(_ h: HostResult) -> Bool {
        procsExpanded[HostKey.of(h)] ?? (h.source == "local")
    }

    func toggleExpanded(_ h: HostResult) {
        procsExpanded[HostKey.of(h)] = !isExpanded(h)
    }

    /// Tests/snapshots: start from a known agent registry.
    func preloadAgents(_ keys: [String]) { agents = AgentRegistry(keys: Set(keys)) }

    func disks(for h: HostResult) -> [Stats.Disk] {
        memory.merged(host: HostKey.of(h), live: h.stats?.disks ?? [])
    }
}

enum FleetError: Error { case status(Int) }

/// Stable per-node key (tailnet IP; name only as a fallback) — the same key
/// AgentRegistry uses.
enum HostKey {
    static func of(_ h: HostResult) -> String { AgentRegistry.key(host: h.host, ip: h.ip) }
}

// CappedLog: append-only line log, truncated to zero when it exceeds 1 MB at
// open time. No unbounded growth (owner had a leak incident with v1).
final class CappedLog {
    let url: URL
    private let handle: FileHandle?
    private let stamp = ISO8601DateFormatter()

    init(name: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        url = dir.appendingPathComponent("\(name).log")
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
           size > 1_000_000 {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    func line(_ s: String) {
        if let d = "\(stamp.string(from: Date())) \(s)\n".data(using: .utf8) {
            try? handle?.write(contentsOf: d)
        }
    }
}
