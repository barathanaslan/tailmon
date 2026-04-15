// ModelsTests.swift -- round-trip decode every Codable struct against
// fixtures derived from src/shared/models.py.

import Foundation
import StudioMenuBar

enum ModelsTests {
    static let decoder = StudioJSON.makeDecoder()

    static func register(_ runner: TestRunner) {
        runner.add("models/healthDecode") { try healthDecode() }
        runner.add("models/statsFullDecode") { try statsFullDecode() }
        runner.add("models/statsNullsDecode") { try statsNullsDecode() }
        runner.add("models/statsRoundTrip") { try statsRoundTrip() }
        runner.add("models/malformedStatsFailsGracefully") { try malformedStatsFailsGracefully() }
        runner.add("models/processesDecode") { try processesDecode() }
        runner.add("models/portsDecode") { try portsDecode() }
        runner.add("models/sshSessionsDecode") { try sshSessionsDecode() }
        runner.add("models/tmuxSessionsDecode") { try tmuxSessionsDecode() }
    }

    static func healthDecode() throws {
        let data = try loadFixture("health")
        let health = try decoder.decode(HealthResponse.self, from: data)
        try expect(health.ok == true)
        try expectEqual(health.version, "0.1.0")
        try expectClose(health.uptimeSeconds, 1234.567)
    }

    static func statsFullDecode() throws {
        let data = try loadFixture("stats")
        let stats = try decoder.decode(StatsResponse.self, from: data)
        try expectClose(stats.cpu.percentTotal, 12.5)
        try expectEqual(stats.cpu.percentPerCore.count, 8)
        try expectEqual(stats.cpu.loadAvg, [1.23, 1.05, 0.98])
        try expectEqual(stats.memory.totalBytes, 103_079_215_104)
        try expectEqual(stats.memory.percent, 50.0)
        try expect(stats.memory.cachedFilesBytes != nil)
        try expectEqual(stats.gpu?.percent, 37.2)
        try expectEqual(stats.gpu?.frequencyMhz, 1380.0)
        try expectEqual(stats.power?.totalWatts, 12.5)
    }

    static func statsNullsDecode() throws {
        let data = try loadFixture("stats_no_gpu_power")
        let stats = try decoder.decode(StatsResponse.self, from: data)
        try expect(stats.gpu == nil)
        try expect(stats.power == nil)
        try expect(stats.memory.cachedFilesBytes == nil)
    }

    static func statsRoundTrip() throws {
        let data = try loadFixture("stats")
        let stats = try decoder.decode(StatsResponse.self, from: data)
        let encoder = StudioJSON.makeEncoder()
        let reEncoded = try encoder.encode(stats)
        let second = try decoder.decode(StatsResponse.self, from: reEncoded)
        try expectEqual(stats.cpu, second.cpu)
        try expectEqual(stats.memory, second.memory)
        try expectEqual(stats.gpu, second.gpu)
        try expectEqual(stats.power, second.power)
    }

    static func malformedStatsFailsGracefully() throws {
        let data = try loadFixture("malformed_stats")
        try expectThrows({
            _ = try decoder.decode(StatsResponse.self, from: data)
        })
    }

    static func processesDecode() throws {
        let data = try loadFixture("processes")
        let resp = try decoder.decode(ProcessListResponse.self, from: data)
        try expectEqual(resp.processes.count, 3)
        try expectEqual(resp.totalCount, 423)
        let first = resp.processes[0]
        try expectEqual(first.pid, 501)
        try expectEqual(first.name, "launchservicesd")
        try expectClose(first.cpuPercent, 35.1)
    }

    static func portsDecode() throws {
        let data = try loadFixture("ports")
        let resp = try decoder.decode(PortListResponse.self, from: data)
        try expectEqual(resp.ports.count, 4)
        try expectEqual(resp.ports[0].port, 22)
        try expectEqual(resp.ports[0].protocolName, "tcp")
        try expectEqual(resp.ports[0].addressFamilies ?? [], ["v4", "v6"])
        try expect(resp.ports[2].addressFamilies == nil)
        try expectEqual(resp.ports[3].protocolName, "udp")
    }

    static func sshSessionsDecode() throws {
        let data = try loadFixture("ssh-sessions")
        let resp = try decoder.decode(SSHSessionListResponse.self, from: data)
        try expectEqual(resp.sessions.count, 2)
        try expectEqual(resp.sessions[0].tailscalePeer?.hostname, "macbook-pro")
        try expectEqual(resp.sessions[0].idleSeconds, 42.0)
        try expect(resp.sessions[1].tailscalePeer == nil)
        try expect(resp.sessions[1].idleSeconds == nil)
    }

    static func tmuxSessionsDecode() throws {
        let data = try loadFixture("tmux-sessions")
        let resp = try decoder.decode(TmuxSessionListResponse.self, from: data)
        try expectEqual(resp.sessions.count, 2)
        try expectEqual(resp.sessions[0].name, "route")
        try expect(resp.sessions[0].attached == true)
        try expect(resp.sessions[1].attached == false)
    }
}
