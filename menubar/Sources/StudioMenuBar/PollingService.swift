// PollingService.swift -- timer-driven poll loop.
//
// Two cadences: 3s when the popover is closed, 1s when it's open. Fires
// five parallel requests per poll (stats / processes / ports / ssh / tmux)
// with `async let`, then hands the result to AppState.

import Foundation

@MainActor
public final class PollingService: ObservableObject {
    private var client: StudioClient
    private weak var appState: AppState?
    private var task: Task<Void, Never>?

    /// Poll interval when the popover is closed.
    public var idleInterval: TimeInterval = 3.0
    /// Poll interval when the popover is open.
    public var openInterval: TimeInterval = 1.0

    @Published public private(set) var popoverOpen: Bool = false

    public init(client: StudioClient, appState: AppState) {
        self.client = client
        self.appState = appState
    }

    public func replaceClient(_ new: StudioClient) {
        self.client = new
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func setPopoverOpen(_ open: Bool) {
        self.popoverOpen = open
    }

    /// Fire one poll right now, outside the schedule. Used after a control
    /// action to refresh the view immediately.
    public func pollNow() {
        Task { [weak self] in
            await self?.pollOnce()
        }
    }

    // MARK: - loop

    private func runLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            let interval = popoverOpen ? openInterval : idleInterval
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    private func pollOnce() async {
        guard let appState = appState else { return }
        do {
            async let stats = client.stats()
            async let processes = client.processes(limit: 10)
            async let ports = client.ports()
            async let ssh = client.sshSessions()
            async let tmux = client.tmuxSessions()
            let (s, p, po, ss, tm) = try await (stats, processes, ports, ssh, tmux)
            appState.apply(stats: s, processes: p, ports: po, ssh: ss, tmux: tm)
        } catch let err as StudioClientError {
            appState.markError(err.shortLabel)
        } catch {
            appState.markError(error.localizedDescription)
        }
    }
}
