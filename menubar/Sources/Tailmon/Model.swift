// Codable mirror of tailmon's JSON (schema 1). Field names follow
// convertFromSnakeCase, so `used_mb` -> usedMb, `cpu_pct` -> cpuPct.
import Foundation

struct Report: Decodable {
    var schema: Int
    var generatedAt: String?
    var hosts: [HostResult]
    var note: String?
}

struct HostResult: Decodable, Identifiable {
    var host: String
    var ip: String?
    var os: String?
    var status: String // live | no-agent | offline
    var source: String?
    var error: String?
    var stats: Stats?

    var id: String { host }
    var isLive: Bool { status == "live" }
}

struct Stats: Decodable {
    var schema: Int
    var host: String
    var os: String
    var arch: String?
    var uptimeSec: UInt64?
    var cpu: CPU
    var mem: Mem
    var gpu: [GPU]?
    var disks: [Disk]?
    var topProcs: [Proc]?
    var agent: AgentSelf?

    struct CPU: Decodable {
        var percent: Double
        var cores: Int
        var load1: Double?
    }

    struct Mem: Decodable {
        var totalMb: UInt64
        var usedMb: UInt64
        var availableMb: UInt64?
        var pressure: String?
        var swapUsedMb: UInt64?
    }

    struct GPU: Decodable {
        var name: String
        var utilPct: Double?
        var vramUsedMb: UInt64?
        var vramTotalMb: UInt64?
        var tempC: Double?
    }

    struct Disk: Decodable {
        var mount: String
        var freeGb: Double
        var totalGb: Double
    }

    struct Proc: Decodable, Identifiable {
        var pid: Int
        var name: String
        var cpuPct: Double
        var memMb: Double
        var command: String?

        var id: Int { pid }
    }

    struct AgentSelf: Decodable {
        var version: String?
        var rssMb: Double?
        var goroutines: Int?
    }
}

func tailmonJSONDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}
