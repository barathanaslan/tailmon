// Config.swift -- mirror of src/studio_cli/config.py for the Swift side.
//
// Precedence (first hit wins, per-key):
//   1. Env var (STUDIO_COLLECTOR_URL / STUDIO_TOKEN / STUDIO_TOKEN_FILE /
//      STUDIO_TIMEOUT / STUDIO_SSH_HOST / STUDIO_CONFIG_FILE).
//   2. ~/.config/studio-cli/config.toml.
//   3. Built-in defaults matching the Python side.
//
// The token is read from `tokenFile` (default
// ~/.config/studio-cli/token). The file MUST be mode 0600; wider modes
// produce a StudioConfigError with a chmod hint rather than a silent load
// of a world-readable secret.

import Foundation

public struct StudioConfigError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public var description: String { message }
    public init(message: String) { self.message = message }
}

public struct ClientConfig: Equatable {
    public var collectorURL: URL
    public var tokenFile: URL
    public var timeoutSeconds: Double
    public var sshHost: String
    public var configFile: URL?
    /// Populated only when STUDIO_TOKEN is set in the environment. Short-
    /// circuits the token-file read entirely.
    public var tokenOverride: String?

    public init(
        collectorURL: URL,
        tokenFile: URL,
        timeoutSeconds: Double,
        sshHost: String,
        configFile: URL?,
        tokenOverride: String?
    ) {
        self.collectorURL = collectorURL
        self.tokenFile = tokenFile
        self.timeoutSeconds = timeoutSeconds
        self.sshHost = sshHost
        self.configFile = configFile
        self.tokenOverride = tokenOverride
    }
}

public enum StudioConfig {

    // MARK: - public defaults (mirror src/studio_cli/config.py)

    public static let defaultCollectorURL = "http://100.80.21.79:8765"
    public static let defaultTimeoutSeconds = 5.0
    public static let defaultSSHHost = "macstudio"

    public static var defaultConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("studio-cli", isDirectory: true)
    }

    public static var defaultConfigFile: URL {
        defaultConfigDir.appendingPathComponent("config.toml", isDirectory: false)
    }

    public static var defaultTokenFile: URL {
        defaultConfigDir.appendingPathComponent("token", isDirectory: false)
    }

    // MARK: - env var names

    public static let envCollectorURL = "STUDIO_COLLECTOR_URL"
    public static let envToken = "STUDIO_TOKEN"
    public static let envTokenFile = "STUDIO_TOKEN_FILE"
    public static let envTimeout = "STUDIO_TIMEOUT"
    public static let envSSHHost = "STUDIO_SSH_HOST"
    public static let envConfigFile = "STUDIO_CONFIG_FILE"

    // MARK: - load

    /// Resolve a `ClientConfig` from env + config file + defaults.
    ///
    /// - Parameters:
    ///   - environment: inject for tests; production passes nothing (uses
    ///     `ProcessInfo.processInfo.environment`).
    ///   - fileManager: inject for tests.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> ClientConfig {
        let configFilePath: URL
        if let override = nonEmpty(environment[envConfigFile]) {
            configFilePath = URL(fileURLWithPath: expandTilde(override))
        } else {
            configFilePath = defaultConfigFile
        }

        let fileData: [String: TOMLScalar]
        if fileManager.fileExists(atPath: configFilePath.path) {
            let raw: String
            do {
                raw = try String(contentsOf: configFilePath, encoding: .utf8)
            } catch {
                throw StudioConfigError(message: "cannot read config file \(configFilePath.path): \(error.localizedDescription)")
            }
            fileData = try TOMLMini.parse(raw, path: configFilePath.path)
        } else {
            fileData = [:]
        }

        func pickString(_ key: String, env: String, fallback: String) throws -> String {
            if let v = nonEmpty(environment[env]) { return v }
            if let v = fileData[key] {
                switch v {
                case .string(let s): return s
                case .number: throw StudioConfigError(message: "config key \(key) must be a string")
                }
            }
            return fallback
        }

        func pickDouble(_ key: String, env: String, fallback: Double) throws -> Double {
            if let s = nonEmpty(environment[env]), let d = Double(s) {
                return d
            }
            if let v = fileData[key] {
                switch v {
                case .number(let d): return d
                case .string(let s):
                    if let d = Double(s) { return d }
                    throw StudioConfigError(message: "config key \(key) must be a number")
                }
            }
            return fallback
        }

        let collectorRaw = try pickString(
            "collector_url",
            env: envCollectorURL,
            fallback: defaultCollectorURL
        )
        let trimmed = collectorRaw.trimmingTrailingSlashes()
        guard let collectorURL = URL(string: trimmed) else {
            throw StudioConfigError(message: "invalid collector_url: \(collectorRaw)")
        }

        let tokenFileRaw = try pickString(
            "token_file",
            env: envTokenFile,
            fallback: defaultTokenFile.path
        )
        let tokenFile = URL(fileURLWithPath: expandTilde(tokenFileRaw))

        let timeout = try pickDouble(
            "timeout_seconds",
            env: envTimeout,
            fallback: defaultTimeoutSeconds
        )

        let sshHost = try pickString(
            "ssh_host",
            env: envSSHHost,
            fallback: defaultSSHHost
        )

        let override = nonEmpty(environment[envToken])

        return ClientConfig(
            collectorURL: collectorURL,
            tokenFile: tokenFile,
            timeoutSeconds: timeout,
            sshHost: sshHost,
            configFile: fileManager.fileExists(atPath: configFilePath.path) ? configFilePath : nil,
            tokenOverride: override
        )
    }

    /// Read the bearer token, enforcing mode 0600.
    /// Honors `STUDIO_TOKEN` override. Raises `StudioConfigError` with a
    /// fix hint on file-not-found / empty / world-readable.
    public static func loadToken(
        _ cfg: ClientConfig,
        fileManager: FileManager = .default
    ) throws -> String {
        if let override = cfg.tokenOverride {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let path = cfg.tokenFile.path
        if !fileManager.fileExists(atPath: path) {
            throw StudioConfigError(message:
                "token file not found: \(path)\n" +
                "Copy it from the Mac Studio:\n" +
                "  scp macstudio:/etc/studiod/token \(path)\n" +
                "  chmod 600 \(path)"
            )
        }
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fileManager.attributesOfItem(atPath: path)
        } catch {
            throw StudioConfigError(message: "cannot stat token file \(path): \(error.localizedDescription)")
        }
        let mode: UInt16
        if let posix = attrs[.posixPermissions] as? NSNumber {
            mode = posix.uint16Value
        } else {
            throw StudioConfigError(message: "cannot determine permissions for token file \(path)")
        }
        if (mode & 0o077) != 0 {
            let modeOctal = String(mode, radix: 8)
            throw StudioConfigError(message:
                "token file \(path) has overly permissive mode 0\(modeOctal) -- want 0600.\n" +
                "Fix with:  chmod 600 \(path)"
            )
        }
        let contents: String
        do {
            contents = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw StudioConfigError(message: "cannot read token file \(path): \(error.localizedDescription)")
        }
        let stripped = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty {
            throw StudioConfigError(message: "token file \(path) is empty")
        }
        return stripped
    }

    // MARK: - helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    public static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + String(path.dropFirst(1))
        }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return path
    }
}

// MARK: - Minimal TOML parser
//
// Supports the exact subset used by ~/.config/studio-cli/config.toml:
//
//   # comment
//   key = "string value"
//   key = 5.0
//
// No tables, no arrays, no inline tables. Four keys are expected
// (collector_url, token_file, timeout_seconds, ssh_host). Anything more
// exotic lives in the Python CLI config loader and the menubar app
// doesn't need it.

public enum TOMLScalar: Equatable {
    case string(String)
    case number(Double)
}

public enum TOMLMini {
    public static func parse(_ text: String, path: String = "<string>") throws -> [String: TOMLScalar] {
        var result: [String: TOMLScalar] = [:]
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = stripInlineComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                // Reject tables -- our minimum schema is flat.
                throw StudioConfigError(message: "\(path):\(lineNumber): tables are not supported by this minimal TOML parser")
            }
            guard let eqIdx = line.firstIndex(of: "=") else {
                throw StudioConfigError(message: "\(path):\(lineNumber): missing '=' in line: \(line)")
            }
            let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let valueRaw = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                throw StudioConfigError(message: "\(path):\(lineNumber): empty key")
            }
            if !isBareKey(key) {
                throw StudioConfigError(message: "\(path):\(lineNumber): unsupported key format: \(key)")
            }
            let value = try parseScalar(String(valueRaw), path: path, line: lineNumber)
            if result[key] != nil {
                throw StudioConfigError(message: "\(path):\(lineNumber): duplicate key \(key)")
            }
            result[key] = value
        }
        return result
    }

    // MARK: - internals

    private static func stripInlineComment(_ line: String) -> String {
        var inString = false
        var result = ""
        for ch in line {
            if ch == "\"" { inString.toggle() }
            if ch == "#" && !inString { break }
            result.append(ch)
        }
        return result
    }

    private static func isBareKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        for ch in key {
            if !(ch.isLetter || ch.isNumber || ch == "_" || ch == "-") {
                return false
            }
        }
        return true
    }

    private static func parseScalar(_ raw: String, path: String, line: Int) throws -> TOMLScalar {
        if raw.hasPrefix("\"") {
            guard raw.hasSuffix("\""), raw.count >= 2 else {
                throw StudioConfigError(message: "\(path):\(line): unterminated string")
            }
            let inner = String(raw.dropFirst().dropLast())
            // Support basic \" and \\ escapes. No unicode escapes because
            // the config keys are all ASCII paths / URLs.
            var out = ""
            var escape = false
            for ch in inner {
                if escape {
                    switch ch {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default:
                        throw StudioConfigError(message: "\(path):\(line): unknown escape \\\(ch)")
                    }
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else {
                    out.append(ch)
                }
            }
            if escape {
                throw StudioConfigError(message: "\(path):\(line): trailing backslash in string")
            }
            return .string(out)
        }
        // Bare single-quoted (literal) strings also tolerated.
        if raw.hasPrefix("'") {
            guard raw.hasSuffix("'"), raw.count >= 2 else {
                throw StudioConfigError(message: "\(path):\(line): unterminated literal string")
            }
            return .string(String(raw.dropFirst().dropLast()))
        }
        if let d = Double(raw) {
            return .number(d)
        }
        throw StudioConfigError(message: "\(path):\(line): cannot parse value: \(raw)")
    }
}

private extension String {
    func trimmingTrailingSlashes() -> String {
        var s = self
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
