// ConfigTests.swift -- TOML parser, config precedence, token mode enforcement.

import Foundation
import StudioMenuBar

enum ConfigTests {
    static func register(_ runner: TestRunner) {
        runner.add("config/tomlParsesSimpleKeys") { try tomlParsesSimpleKeys() }
        runner.add("config/tomlStripsInlineComments") { try tomlStripsInlineComments() }
        runner.add("config/tomlRejectsMalformedLine") { try tomlRejectsMalformedLine() }
        runner.add("config/tomlRejectsTables") { try tomlRejectsTables() }
        runner.add("config/tomlRejectsDuplicateKeys") { try tomlRejectsDuplicateKeys() }
        runner.add("config/tomlEmptyIsOK") { try tomlEmptyIsOK() }
        runner.add("config/defaultsWhenNoFileAndNoEnv") { try defaultsWhenNoFileAndNoEnv() }
        runner.add("config/envOverridesFile") { try envOverridesFile() }
        runner.add("config/fileUsedWhenNoEnv") { try fileUsedWhenNoEnv() }
        runner.add("config/tokenLoadsFromEnvOverride") { try tokenLoadsFromEnvOverride() }
        runner.add("config/tokenMissingFileErrors") { try tokenMissingFileErrors() }
        runner.add("config/tokenRejectsWorldReadableMode") { try tokenRejectsWorldReadableMode() }
        runner.add("config/tokenAccepts0600Mode") { try tokenAccepts0600Mode() }
        runner.add("config/tokenEmptyFileErrors") { try tokenEmptyFileErrors() }
    }

    // MARK: - TOML parser

    static func tomlParsesSimpleKeys() throws {
        let text = """
        # this is a comment
        collector_url = "http://127.0.0.1:8765"
        token_file = "/Users/test/.config/studio-cli/token"
        timeout_seconds = 5.0
        ssh_host = "macstudio"
        """
        let parsed = try TOMLMini.parse(text)
        try expectEqual(parsed["collector_url"], .string("http://127.0.0.1:8765"))
        try expectEqual(parsed["token_file"], .string("/Users/test/.config/studio-cli/token"))
        try expectEqual(parsed["timeout_seconds"], .number(5.0))
        try expectEqual(parsed["ssh_host"], .string("macstudio"))
    }

    static func tomlStripsInlineComments() throws {
        let parsed = try TOMLMini.parse(#"key = "value" # trailing comment"#)
        try expectEqual(parsed["key"], .string("value"))
    }

    static func tomlRejectsMalformedLine() throws {
        try expectThrows({
            _ = try TOMLMini.parse("no equals sign here")
        })
    }

    static func tomlRejectsTables() throws {
        try expectThrows({
            _ = try TOMLMini.parse("[section]\nfoo = \"bar\"")
        })
    }

    static func tomlRejectsDuplicateKeys() throws {
        try expectThrows({
            _ = try TOMLMini.parse("foo = \"a\"\nfoo = \"b\"")
        })
    }

    static func tomlEmptyIsOK() throws {
        let parsed = try TOMLMini.parse("")
        try expect(parsed.isEmpty)
    }

    // MARK: - config precedence

    static func defaultsWhenNoFileAndNoEnv() throws {
        let cfg = try StudioConfig.load(
            environment: ["STUDIO_CONFIG_FILE": "/nonexistent/path/config.toml"]
        )
        try expectEqual(cfg.collectorURL.absoluteString, "http://100.80.21.79:8765")
        try expectEqual(cfg.timeoutSeconds, 5.0)
        try expectEqual(cfg.sshHost, "macstudio")
    }

    static func envOverridesFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString).toml")
        try #"collector_url = "http://10.0.0.1:1111""#.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cfg = try StudioConfig.load(
            environment: [
                "STUDIO_CONFIG_FILE": tmp.path,
                "STUDIO_COLLECTOR_URL": "http://127.0.0.1:9999",
            ]
        )
        try expectEqual(cfg.collectorURL.absoluteString, "http://127.0.0.1:9999")
    }

    static func fileUsedWhenNoEnv() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString).toml")
        try """
        collector_url = "http://10.0.0.1:1111"
        timeout_seconds = 2.5
        """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cfg = try StudioConfig.load(environment: ["STUDIO_CONFIG_FILE": tmp.path])
        try expectEqual(cfg.collectorURL.absoluteString, "http://10.0.0.1:1111")
        try expectEqual(cfg.timeoutSeconds, 2.5)
    }

    // MARK: - token mode enforcement

    static func tokenLoadsFromEnvOverride() throws {
        let cfg = ClientConfig(
            collectorURL: URL(string: "http://127.0.0.1")!,
            tokenFile: URL(fileURLWithPath: "/nonexistent"),
            timeoutSeconds: 5, sshHost: "x",
            configFile: nil, tokenOverride: "  abc123  "
        )
        let t = try StudioConfig.loadToken(cfg)
        try expectEqual(t, "abc123")
    }

    static func tokenMissingFileErrors() throws {
        let cfg = ClientConfig(
            collectorURL: URL(string: "http://127.0.0.1")!,
            tokenFile: URL(fileURLWithPath: "/nonexistent/token"),
            timeoutSeconds: 5, sshHost: "x",
            configFile: nil, tokenOverride: nil
        )
        try expectThrows({
            _ = try StudioConfig.loadToken(cfg)
        })
    }

    static func tokenRejectsWorldReadableMode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("token")
        try "secret-token-value".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)

        let cfg = ClientConfig(
            collectorURL: URL(string: "http://127.0.0.1")!,
            tokenFile: path,
            timeoutSeconds: 5, sshHost: "x",
            configFile: nil, tokenOverride: nil
        )
        do {
            _ = try StudioConfig.loadToken(cfg)
            throw TestFailure.assertion("expected error", #file, #line)
        } catch let err as StudioConfigError {
            try expect(err.message.contains("0600"), "error should mention 0600, got: \(err.message)")
        } catch let err as TestFailure {
            throw err
        } catch {
            throw TestFailure.assertion("wrong error type: \(error)", #file, #line)
        }
    }

    static func tokenAccepts0600Mode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("token")
        try "real-secret\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        let cfg = ClientConfig(
            collectorURL: URL(string: "http://127.0.0.1")!,
            tokenFile: path,
            timeoutSeconds: 5, sshHost: "x",
            configFile: nil, tokenOverride: nil
        )
        let token = try StudioConfig.loadToken(cfg)
        try expectEqual(token, "real-secret")
    }

    static func tokenEmptyFileErrors() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("token")
        try "".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)

        let cfg = ClientConfig(
            collectorURL: URL(string: "http://127.0.0.1")!,
            tokenFile: path,
            timeoutSeconds: 5, sshHost: "x",
            configFile: nil, tokenOverride: nil
        )
        try expectThrows({
            _ = try StudioConfig.loadToken(cfg)
        })
    }
}
