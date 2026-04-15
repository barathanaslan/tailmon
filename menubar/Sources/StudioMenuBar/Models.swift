// Models.swift -- Codable structs matching src/shared/models.py (pydantic v2).
//
// Field names mirror the Python side exactly and use JSON snake_case via
// explicit CodingKeys. Everything here is `public` so the test executable
// target can link against the library target.

import Foundation

// MARK: - /health

public struct HealthResponse: Codable, Equatable {
    public let ok: Bool
    public let version: String
    public let uptimeSeconds: Double

    public init(ok: Bool, version: String, uptimeSeconds: Double) {
        self.ok = ok
        self.version = version
        self.uptimeSeconds = uptimeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case version
        case uptimeSeconds = "uptime_seconds"
    }
}

// MARK: - /stats

public struct CPUStats: Codable, Equatable {
    public let percentTotal: Double
    public let percentPerCore: [Double]
    public let loadAvg: [Double]

    public init(percentTotal: Double, percentPerCore: [Double], loadAvg: [Double]) {
        self.percentTotal = percentTotal
        self.percentPerCore = percentPerCore
        self.loadAvg = loadAvg
    }

    enum CodingKeys: String, CodingKey {
        case percentTotal = "percent_total"
        case percentPerCore = "percent_per_core"
        case loadAvg = "load_avg"
    }
}

public struct MemoryStats: Codable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64
    public let percent: Double
    public let swapUsedBytes: Int64
    public let swapTotalBytes: Int64
    public let appMemoryBytes: Int64?
    public let wiredBytes: Int64?
    public let compressedBytes: Int64?
    public let cachedFilesBytes: Int64?

    public init(
        totalBytes: Int64,
        usedBytes: Int64,
        availableBytes: Int64,
        percent: Double,
        swapUsedBytes: Int64,
        swapTotalBytes: Int64,
        appMemoryBytes: Int64?,
        wiredBytes: Int64?,
        compressedBytes: Int64?,
        cachedFilesBytes: Int64?
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
        self.percent = percent
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.appMemoryBytes = appMemoryBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
    }

    enum CodingKeys: String, CodingKey {
        case totalBytes = "total_bytes"
        case usedBytes = "used_bytes"
        case availableBytes = "available_bytes"
        case percent
        case swapUsedBytes = "swap_used_bytes"
        case swapTotalBytes = "swap_total_bytes"
        case appMemoryBytes = "app_memory_bytes"
        case wiredBytes = "wired_bytes"
        case compressedBytes = "compressed_bytes"
        case cachedFilesBytes = "cached_files_bytes"
    }
}

public struct GPUStats: Codable, Equatable {
    public let percent: Double
    public let frequencyMhz: Double?

    public init(percent: Double, frequencyMhz: Double?) {
        self.percent = percent
        self.frequencyMhz = frequencyMhz
    }

    enum CodingKeys: String, CodingKey {
        case percent
        case frequencyMhz = "frequency_mhz"
    }
}

public struct PowerStats: Codable, Equatable {
    public let cpuPackageWatts: Double
    public let gpuWatts: Double
    public let totalWatts: Double

    public init(cpuPackageWatts: Double, gpuWatts: Double, totalWatts: Double) {
        self.cpuPackageWatts = cpuPackageWatts
        self.gpuWatts = gpuWatts
        self.totalWatts = totalWatts
    }

    enum CodingKeys: String, CodingKey {
        case cpuPackageWatts = "cpu_package_watts"
        case gpuWatts = "gpu_watts"
        case totalWatts = "total_watts"
    }
}

public struct StatsResponse: Codable, Equatable {
    public let cpu: CPUStats
    public let memory: MemoryStats
    public let gpu: GPUStats?
    public let power: PowerStats?
    public let timestamp: Date

    public init(cpu: CPUStats, memory: MemoryStats, gpu: GPUStats?, power: PowerStats?, timestamp: Date) {
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.power = power
        self.timestamp = timestamp
    }
}

// MARK: - /processes

public struct StudioProcess: Codable, Equatable, Identifiable {
    public let pid: Int
    public let ppid: Int
    public let user: String
    public let name: String
    public let cmdline: String
    public let cpuPercent: Double
    public let memoryRssBytes: Int64
    public let memoryPercent: Double
    public let status: String
    public let createTime: Date

    public var id: Int { pid }

    public init(
        pid: Int, ppid: Int, user: String, name: String, cmdline: String,
        cpuPercent: Double, memoryRssBytes: Int64, memoryPercent: Double,
        status: String, createTime: Date
    ) {
        self.pid = pid
        self.ppid = ppid
        self.user = user
        self.name = name
        self.cmdline = cmdline
        self.cpuPercent = cpuPercent
        self.memoryRssBytes = memoryRssBytes
        self.memoryPercent = memoryPercent
        self.status = status
        self.createTime = createTime
    }

    enum CodingKeys: String, CodingKey {
        case pid, ppid, user, name, cmdline, status
        case cpuPercent = "cpu_percent"
        case memoryRssBytes = "memory_rss_bytes"
        case memoryPercent = "memory_percent"
        case createTime = "create_time"
    }
}

public struct ProcessListResponse: Codable, Equatable {
    public let processes: [StudioProcess]
    public let totalCount: Int
    public let sampledAt: Date

    public init(processes: [StudioProcess], totalCount: Int, sampledAt: Date) {
        self.processes = processes
        self.totalCount = totalCount
        self.sampledAt = sampledAt
    }

    enum CodingKeys: String, CodingKey {
        case processes
        case totalCount = "total_count"
        case sampledAt = "sampled_at"
    }
}

// MARK: - /ports

public struct PortInfo: Codable, Equatable, Identifiable {
    public let protocolName: String
    public let address: String
    public let port: Int
    public let pid: Int?
    public let processName: String?
    public let user: String?
    public let addressFamilies: [String]?

    public var id: String {
        "\(protocolName)-\(address)-\(port)-\(pid ?? 0)"
    }

    public init(
        protocolName: String, address: String, port: Int,
        pid: Int?, processName: String?, user: String?,
        addressFamilies: [String]?
    ) {
        self.protocolName = protocolName
        self.address = address
        self.port = port
        self.pid = pid
        self.processName = processName
        self.user = user
        self.addressFamilies = addressFamilies
    }

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case address, port, pid, user
        case processName = "process_name"
        case addressFamilies = "address_families"
    }
}

public struct PortListResponse: Codable, Equatable {
    public let ports: [PortInfo]
    public let sampledAt: Date

    public init(ports: [PortInfo], sampledAt: Date) {
        self.ports = ports
        self.sampledAt = sampledAt
    }

    enum CodingKeys: String, CodingKey {
        case ports
        case sampledAt = "sampled_at"
    }
}

// MARK: - /ssh/sessions

public struct TailscalePeer: Codable, Equatable {
    public let hostname: String
    public let tailscaleIp: String
    public let os: String?
    public let userDisplayName: String?

    public init(hostname: String, tailscaleIp: String, os: String?, userDisplayName: String?) {
        self.hostname = hostname
        self.tailscaleIp = tailscaleIp
        self.os = os
        self.userDisplayName = userDisplayName
    }

    enum CodingKeys: String, CodingKey {
        case hostname, os
        case tailscaleIp = "tailscale_ip"
        case userDisplayName = "user_display_name"
    }
}

public struct SSHSession: Codable, Equatable, Identifiable {
    public let pid: Int
    public let user: String
    public let sourceIp: String
    public let sourcePort: Int
    public let tailscalePeer: TailscalePeer?
    public let tty: String?
    public let startedAt: Date
    public let idleSeconds: Double?

    public var id: Int { pid }

    public init(
        pid: Int, user: String, sourceIp: String, sourcePort: Int,
        tailscalePeer: TailscalePeer?, tty: String?,
        startedAt: Date, idleSeconds: Double?
    ) {
        self.pid = pid
        self.user = user
        self.sourceIp = sourceIp
        self.sourcePort = sourcePort
        self.tailscalePeer = tailscalePeer
        self.tty = tty
        self.startedAt = startedAt
        self.idleSeconds = idleSeconds
    }

    enum CodingKeys: String, CodingKey {
        case pid, user, tty
        case sourceIp = "source_ip"
        case sourcePort = "source_port"
        case tailscalePeer = "tailscale_peer"
        case startedAt = "started_at"
        case idleSeconds = "idle_seconds"
    }
}

public struct SSHSessionListResponse: Codable, Equatable {
    public let sessions: [SSHSession]
    public let sampledAt: Date

    public init(sessions: [SSHSession], sampledAt: Date) {
        self.sessions = sessions
        self.sampledAt = sampledAt
    }

    enum CodingKeys: String, CodingKey {
        case sessions
        case sampledAt = "sampled_at"
    }
}

// MARK: - /tmux/sessions

public struct TmuxSession: Codable, Equatable, Identifiable {
    public let name: String
    public let windows: Int
    public let attached: Bool
    public let createdAt: Date?

    public var id: String { name }

    public init(name: String, windows: Int, attached: Bool, createdAt: Date?) {
        self.name = name
        self.windows = windows
        self.attached = attached
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case name, windows, attached
        case createdAt = "created_at"
    }
}

public struct TmuxSessionListResponse: Codable, Equatable {
    public let sessions: [TmuxSession]
    public let sampledAt: Date

    public init(sessions: [TmuxSession], sampledAt: Date) {
        self.sessions = sessions
        self.sampledAt = sampledAt
    }

    enum CodingKeys: String, CodingKey {
        case sessions
        case sampledAt = "sampled_at"
    }
}

// MARK: - Error envelope

public struct ErrorResponse: Codable, Equatable {
    public let error: String?
    public let detail: String?
}

// MARK: - JSON coder factory

public enum StudioJSON {
    public static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = StudioJSON.iso8601FractionalFormatter.date(from: raw) {
                return date
            }
            if let date = StudioJSON.iso8601Formatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized ISO-8601 timestamp: \(raw)"
            )
        }
        return dec
    }

    public static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(fmt.string(from: date))
        }
        return enc
    }

    static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
