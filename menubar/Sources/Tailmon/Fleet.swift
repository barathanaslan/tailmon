// FleetModel drives the whole app. Efficiency contract (owner requirement):
// while the menu is CLOSED the only activity is one localhost URLSession poll
// plus up to a handful of tiny /health probes to known peers every 15s for
// the menu-bar label — ZERO subprocess spawns. Fleet queries (spawning
// `tailmon json`) happen only while the menu is OPEN, every 3s, one in
// flight at most. No history is kept: latest snapshot only.
//
// NO power controls anywhere in this app — owner rule (2026-07-10).
import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class FleetModel: ObservableObject {
    @Published var iconImage: NSImage?
    @Published var report: Report?
    @Published var fleetError: String?
    @Published var menuOpen = false {
        didSet { if menuOpen != oldValue { reschedule(fireNow: menuOpen) } }
    }

    private var timer: Timer?
    private var fleetInFlight = false
    private var iconInFlight = false
    private let session: URLSession
    private let tailmonPath: String?
    private let log = CappedLog(name: "tailmon-menubar")

    // Peers learned from the last successful fleet fetch, persisted so the
    // label can show device status from the very first (menu-closed) tick.
    private var knownPeers: [(name: String, ip: String)] = []
    private var peerStatuses: [String: PeerBadge.Status] = [:]

    static let closedInterval: TimeInterval = 15
    static let openInterval: TimeInterval = 3
    private static let peersKey = "knownPeers"
    private static let autoLoginKey = "didAutoRegisterLoginItem"

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 3
        session = URLSession(configuration: cfg)
        tailmonPath = Self.findTailmon()
        loadPeers()
        registerLoginItemOnce()
        log.line("launch; tailmon binary: \(tailmonPath ?? "NOT FOUND")")
        reschedule(fireNow: true)
    }

    // Launch at login is the DEFAULT (owner: the fleet contains machines that
    // boot unattended — monitoring must survive reboots). Registered once; if
    // the owner disables it later in System Settings we never re-force it.
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

    private static func findTailmon() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["\(home)/bin/tailmon", "/usr/local/bin/tailmon", "/opt/homebrew/bin/tailmon"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    private func reschedule(fireNow: Bool) {
        timer?.invalidate()
        let interval = menuOpen ? Self.openInterval : Self.closedInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // .common keeps the label updating while menus/tracking run.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if fireNow { tick() }
    }

    private func tick() {
        // Menu open: the fleet fetch is the single data path — the label is
        // derived from its local-host entry (no separate poll, no double
        // sampling of this machine). Menu closed: only the cheap label poll.
        if menuOpen {
            refreshFleet()
        } else {
            refreshIcon()
        }
    }

    // MARK: - Label (local stats + peer probes; no subprocesses, ever)

    private func refreshIcon() {
        guard !iconInFlight else { return }
        iconInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let stats = await self.fetchLocalStats()
            // While the menu is open the fleet fetch refreshes statuses with
            // better granularity; probe only when closed.
            if !self.menuOpen { await self.probePeers() }
            self.iconImage = IconRenderer.render(
                IconInfo.make(stats: stats, peers: self.currentBadges()))
            self.iconInFlight = false
        }
    }

    private func fetchLocalStats() async -> Stats? {
        guard let url = URL(string: "http://127.0.0.1:7020/stats?top=1") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            return try tailmonJSONDecoder().decode(Stats.self, from: data)
        } catch {
            return nil
        }
    }

    private func probePeers() async {
        await withTaskGroup(of: (String, PeerBadge.Status).self) { group in
            for peer in knownPeers {
                let session = self.session
                group.addTask {
                    guard let url = URL(string: "http://\(peer.ip):7020/health") else {
                        return (peer.name, .unknown)
                    }
                    do {
                        _ = try await session.data(from: url)
                        return (peer.name, .live)
                    } catch let e as URLError where e.code == .timedOut {
                        return (peer.name, .offline) // tailscale blackholes offline IPs
                    } catch {
                        return (peer.name, .noAgent) // reachable, port closed
                    }
                }
            }
            for await (name, status) in group { peerStatuses[name] = status }
        }
    }

    private func currentBadges() -> [PeerBadge] {
        knownPeers.map {
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
        let peers = report.hosts
            .filter { $0.source != "local" }
            .compactMap { h -> (String, String)? in
                guard let ip = h.ip, !ip.isEmpty else { return nil }
                return (h.host, ip)
            }
            .sorted { $0.0 < $1.0 }
        knownPeers = peers.map { (name: $0.0, ip: $0.1) }
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

    // MARK: - Fleet (menu open only; spawns `tailmon json --top 10`)

    private func refreshFleet() {
        guard !fleetInFlight else { return }
        guard let bin = tailmonPath else {
            fleetError = "tailmon binary not found in ~/bin — run ~/tailmon/deploy/install-macos.sh"
            return
        }
        fleetInFlight = true
        Task.detached { [weak self] in
            let result = Self.runTailmonJSON(bin: bin)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fleetInFlight = false
                switch result {
                case .success(let r):
                    self.report = r
                    self.fleetError = nil
                    self.updatePeers(from: r)
                    let localStats = r.hosts.first { $0.source == "local" }?.stats
                    self.iconImage = IconRenderer.render(
                        IconInfo.make(stats: localStats, peers: self.currentBadges()))
                case .failure(let e):
                    self.fleetError = e.localizedDescription
                    self.log.line("fleet fetch failed: \(e.localizedDescription)")
                }
            }
        }
    }

    nonisolated private static func runTailmonJSON(bin: String) -> Result<Report, Error> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["json", "--top", "10"]
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice

        // Hang guard: hard-kill after 8s (json itself bounds host requests
        // to 800ms, so a healthy run finishes in ~1-2s).
        let killer = DispatchWorkItem { proc.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
        defer { killer.cancel() }

        do {
            try proc.run()
        } catch {
            return .failure(error)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            return .failure(TailmonError("tailmon json exited \(proc.terminationStatus)"))
        }
        do {
            return .success(try tailmonJSONDecoder().decode(Report.self, from: data))
        } catch {
            return .failure(error)
        }
    }
}

struct TailmonError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// CappedLog: append-only line log, truncated to zero when it exceeds 1 MB at
// open time. No unbounded growth (owner had a leak incident with v1).
final class CappedLog {
    private let handle: FileHandle?

    init(name: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        let url = dir.appendingPathComponent("\(name).log")
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

    func line(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let d = "\(stamp) \(s)\n".data(using: .utf8) {
            try? handle?.write(contentsOf: d)
        }
    }
}
