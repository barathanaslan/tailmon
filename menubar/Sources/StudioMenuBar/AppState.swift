// AppState.swift -- observable state for the menubar app.
//
// Owns the current snapshot of all five endpoints plus ring buffers for
// CPU / GPU / MEM / total-power history. Views observe this via
// @ObservedObject / @EnvironmentObject.

import Foundation
import SwiftUI

/// Ring buffer of floating-point history samples for the sparklines.
/// Fixed capacity (default 60). Cheap to read as an Array for Charts.
public struct HistoryRing: Equatable {
    public private(set) var samples: [Double]
    public let capacity: Int

    public init(capacity: Int = 60) {
        self.capacity = capacity
        self.samples = []
    }

    public mutating func push(_ value: Double) {
        samples.append(value)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Index-paired view for SwiftUI Charts.
    public var indexed: [(Int, Double)] {
        samples.enumerated().map { ($0.offset, $0.element) }
    }

    public var latest: Double? { samples.last }
}

public enum ConnectionState: Equatable {
    case idle                  // no poll completed yet
    case connected             // last poll succeeded
    case error(String)         // last poll failed; message for banner
}

@MainActor
public final class AppState: ObservableObject {
    public init() {}

    // MARK: - snapshot data

    @Published public var stats: StatsResponse?
    @Published public var processes: [StudioProcess] = []
    @Published public var ports: [PortInfo] = []
    @Published public var sshSessions: [SSHSession] = []
    @Published public var tmuxSessions: [TmuxSession] = []

    // MARK: - connection state

    @Published public var connection: ConnectionState = .idle
    @Published public var lastPollAt: Date?
    @Published public var configError: String?

    // MARK: - ring buffers

    @Published public var cpuHistory = HistoryRing()
    @Published public var gpuHistory = HistoryRing()
    @Published public var memHistory = HistoryRing()
    @Published public var powerHistory = HistoryRing()

    // MARK: - config

    @Published public var clientConfig: ClientConfig?

    // MARK: - apply snapshots

    public func apply(
        stats: StatsResponse?,
        processes: ProcessListResponse?,
        ports: PortListResponse?,
        ssh: SSHSessionListResponse?,
        tmux: TmuxSessionListResponse?
    ) {
        if let stats = stats {
            self.stats = stats
            cpuHistory.push(stats.cpu.percentTotal)
            memHistory.push(stats.memory.percent)
            if let gpu = stats.gpu {
                gpuHistory.push(gpu.percent)
            } else {
                gpuHistory.push(0)
            }
            if let power = stats.power {
                powerHistory.push(power.totalWatts)
            } else {
                powerHistory.push(0)
            }
        }
        if let procs = processes {
            self.processes = procs.processes
        }
        if let ports = ports {
            self.ports = ports.ports
        }
        if let ssh = ssh {
            self.sshSessions = ssh.sessions
        }
        if let tmux = tmux {
            self.tmuxSessions = tmux.sessions
        }
        self.lastPollAt = Date()
        self.connection = .connected
    }

    public func markError(_ message: String) {
        self.connection = .error(message)
        self.lastPollAt = Date()
    }
}
