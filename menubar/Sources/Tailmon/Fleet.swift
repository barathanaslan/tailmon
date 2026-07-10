// FleetModel drives the whole app. Efficiency contract (owner requirement):
// while the menu is CLOSED the only activity is one localhost URLSession poll
// every 15s for the menu-bar label — zero subprocess spawns. Fleet queries
// (spawning `tailmon json`) happen only while the menu is OPEN, every 3s, one
// in flight at most. No history is kept: latest snapshot only.
//
// NO power controls anywhere in this app — owner rule (2026-07-10).
import Foundation
import SwiftUI

@MainActor
final class FleetModel: ObservableObject {
    @Published var iconText = "…"
    @Published var report: Report?
    @Published var fleetError: String?
    @Published var menuOpen = false {
        didSet { if menuOpen != oldValue { reschedule(fireNow: menuOpen) } }
    }

    private var timer: Timer?
    private var fleetInFlight = false
    private let session: URLSession
    private let tailmonPath: String?
    private let log = CappedLog(name: "tailmon-menubar")

    static let closedInterval: TimeInterval = 15
    static let openInterval: TimeInterval = 3

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 3
        session = URLSession(configuration: cfg)
        tailmonPath = Self.findTailmon()
        log.line("launch; tailmon binary: \(tailmonPath ?? "NOT FOUND")")
        reschedule(fireNow: true)
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
        refreshIcon()
        if menuOpen { refreshFleet() }
    }

    // MARK: - Icon (local agent, cheap, no subprocess)

    private func refreshIcon() {
        guard let url = URL(string: "http://127.0.0.1:7020/stats?top=1") else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, _) = try await self.session.data(from: url)
                let s = try tailmonJSONDecoder().decode(Stats.self, from: data)
                self.iconText = Self.iconLabel(for: s)
            } catch {
                self.iconText = "–"
            }
        }
    }

    nonisolated static func iconLabel(for s: Stats) -> String {
        let cpu = Int(s.cpu.percent.rounded())
        let usedG = Double(s.mem.usedMb) / 1024
        var label = String(format: "%d%% %.0fG", cpu, usedG)
        switch s.mem.pressure {
        case "warn": label += " ⚠︎"
        case "critical": label += " ‼︎"
        default: break
        }
        return label
    }

    // MARK: - Fleet (menu open only; spawns `tailmon json --top 10`)

    private func refreshFleet() {
        guard !fleetInFlight else { return }
        guard let bin = tailmonPath else {
            fleetError = "tailmon binary not found in ~/bin — run studio-cli/deploy/install-macos.sh"
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
