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

    // Host names are not unique on a tailnet (a cloned machine can share its
    // original's hostname); a duplicate id makes ForEach draw both rows from
    // one entry. The tailnet IP is unique per node.
    var id: String { "\(ip ?? "")/\(host)" }
    var isLive: Bool { status == "live" }
}

// AgentRegistry remembers every node that has ever answered with a live
// agent. "offline" and "no-agent" only mean something for those nodes; a node
// that never ran tailmon (someone else's machine, a phone) is not part of the
// fleet and stays out of the dropdown and the label. Keyed by tailnet IP,
// which is stable per node, unlike the OS hostname.
struct AgentRegistry {
    private(set) var keys: Set<String>

    init(keys: Set<String> = []) { self.keys = keys }

    static func key(host: String, ip: String?) -> String {
        if let ip, !ip.isEmpty { return ip }
        return "name:" + host
    }

    func contains(host: String, ip: String?) -> Bool {
        keys.contains(Self.key(host: host, ip: ip))
    }

    /// Returns true when a new node was learned.
    @discardableResult
    mutating func recordLive(host: String, ip: String?) -> Bool {
        keys.insert(Self.key(host: host, ip: ip)).inserted
    }

    @discardableResult
    mutating func record(_ hosts: [HostResult]) -> Bool {
        var learned = false
        for h in hosts where h.isLive { learned = recordLive(host: h.host, ip: h.ip) || learned }
        return learned
    }

    /// The local machine always shows: it is sampled in-process even without
    /// an agent.
    func visible(_ hosts: [HostResult]) -> [HostResult] {
        hosts.filter { $0.isLive || $0.source == "local" || contains(host: $0.host, ip: $0.ip) }
    }
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
