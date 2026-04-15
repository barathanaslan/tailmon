// PollingServiceTests.swift -- state transitions and ring-buffer behavior.

import Foundation
import StudioMenuBar

enum PollingServiceTests {
    static func register(_ runner: TestRunner) {
        runner.add("polling/historyRingRespectsCapacity") { try historyRingRespectsCapacity() }
        runner.add("polling/historyRingEmpty") { try historyRingEmpty() }
        runner.addAsync("polling/appStateApplyUpdatesHistoryAndConnection") {
            await appStateApplyUpdatesHistoryAndConnection()
        }
        runner.addAsync("polling/appStateMarkErrorSetsErrorState") {
            await appStateMarkErrorSetsErrorState()
        }
        runner.addAsync("polling/pollingServiceCadenceFlag") {
            await pollingServiceCadenceFlag()
        }
        runner.addAsync("polling/appStateWithMissingGPUStillPushesZero") {
            await appStateWithMissingGPUStillPushesZero()
        }
    }

    static func historyRingRespectsCapacity() throws {
        var ring = HistoryRing(capacity: 3)
        ring.push(1)
        ring.push(2)
        ring.push(3)
        ring.push(4)
        try expectEqual(ring.samples, [2, 3, 4])
        try expectEqual(ring.latest, 4)
    }

    static func historyRingEmpty() throws {
        let ring = HistoryRing(capacity: 5)
        try expect(ring.samples.isEmpty)
        try expect(ring.latest == nil)
    }

    @MainActor
    static func appStateApplyUpdatesHistoryAndConnection() async {
        let state = AppState()
        do {
            try expect(state.connection == .idle)

            let stats = StatsResponse(
                cpu: CPUStats(percentTotal: 42, percentPerCore: [10, 20, 30, 40], loadAvg: [1, 1, 1]),
                memory: MemoryStats(
                    totalBytes: 100, usedBytes: 50, availableBytes: 50, percent: 50,
                    swapUsedBytes: 0, swapTotalBytes: 0,
                    appMemoryBytes: nil, wiredBytes: nil,
                    compressedBytes: nil, cachedFilesBytes: nil
                ),
                gpu: GPUStats(percent: 25, frequencyMhz: 1000),
                power: PowerStats(cpuPackageWatts: 5, gpuWatts: 2, totalWatts: 10),
                timestamp: Date()
            )
            state.apply(stats: stats, processes: nil, ports: nil, ssh: nil, tmux: nil)

            try expect(state.connection == .connected)
            try expectEqual(state.cpuHistory.latest, 42)
            try expectEqual(state.gpuHistory.latest, 25)
            try expectEqual(state.memHistory.latest, 50)
            try expectEqual(state.powerHistory.latest, 10)
        } catch {
            fatalError("\(error)")
        }
    }

    @MainActor
    static func appStateMarkErrorSetsErrorState() async {
        let state = AppState()
        state.markError("test error")
        guard case .error(let msg) = state.connection else {
            fatalError("expected error state")
        }
        if msg != "test error" { fatalError("wrong message: \(msg)") }
    }

    @MainActor
    static func pollingServiceCadenceFlag() async {
        let state = AppState()
        let client = StudioClient(
            baseURL: URL(string: "http://127.0.0.1")!,
            token: nil, timeout: 1,
            session: MockSession.make()
        )
        let polling = PollingService(client: client, appState: state)
        if polling.popoverOpen { fatalError("expected closed") }
        polling.setPopoverOpen(true)
        if !polling.popoverOpen { fatalError("expected open") }
        polling.setPopoverOpen(false)
        if polling.popoverOpen { fatalError("expected closed") }
    }

    @MainActor
    static func appStateWithMissingGPUStillPushesZero() async {
        let state = AppState()
        let stats = StatsResponse(
            cpu: CPUStats(percentTotal: 5, percentPerCore: [5], loadAvg: [0, 0, 0]),
            memory: MemoryStats(
                totalBytes: 1, usedBytes: 0, availableBytes: 1, percent: 0,
                swapUsedBytes: 0, swapTotalBytes: 0,
                appMemoryBytes: nil, wiredBytes: nil,
                compressedBytes: nil, cachedFilesBytes: nil
            ),
            gpu: nil,
            power: nil,
            timestamp: Date()
        )
        state.apply(stats: stats, processes: nil, ports: nil, ssh: nil, tmux: nil)
        if state.gpuHistory.latest != 0 { fatalError("expected 0") }
        if state.powerHistory.latest != 0 { fatalError("expected 0") }
    }
}
