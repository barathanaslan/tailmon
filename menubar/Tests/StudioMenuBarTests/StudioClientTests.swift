// StudioClientTests.swift -- HTTP client happy/error paths via MockURLProtocol.

import Foundation
import StudioMenuBar

enum StudioClientTests {
    static let baseURL = URL(string: "http://100.80.21.79:8765")!

    static func register(_ runner: TestRunner) {
        runner.addAsync("client/healthHappy") { try await healthHappy() }
        runner.addAsync("client/statsHappy") { try await statsHappy() }
        runner.addAsync("client/processesHappy") { try await processesHappy() }
        runner.addAsync("client/portsHappy") { try await portsHappy() }
        runner.addAsync("client/sshSessionsHappy") { try await sshSessionsHappy() }
        runner.addAsync("client/tmuxSessionsHappy") { try await tmuxSessionsHappy() }
        runner.addAsync("client/unauthorizedReturns401") { try await unauthorizedReturns401() }
        runner.addAsync("client/serverErrorMaps") { try await serverErrorMaps() }
        runner.addAsync("client/connectionRefusedMapsToConnectionFailed") { try await connectionRefusedMapsToConnectionFailed() }
        runner.addAsync("client/timeoutMaps") { try await timeoutMaps() }
        runner.addAsync("client/notFoundOnKill") { try await notFoundOnKill() }
        runner.addAsync("client/killPostsCorrectly") { try await killPostsCorrectly() }
        runner.addAsync("client/tmuxNewPostsCorrectly") { try await tmuxNewPostsCorrectly() }
        runner.addAsync("client/sshKickPostsCorrectly") { try await sshKickPostsCorrectly() }
    }

    static func okResponse(for url: URL, code: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"])!
    }

    static func makeClient() -> StudioClient {
        StudioClient(baseURL: baseURL, token: "testtoken", timeout: 5, session: MockSession.make())
    }

    // MARK: - happy paths

    static func healthHappy() async throws {
        let data = try loadFixture("health")
        MockURLProtocol.handler = { req in
            try expect(req.url?.path.hasSuffix("/health") == true)
            return (okResponse(for: req.url!), data)
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        let health = try await client.health()
        try expect(health.ok == true)
    }

    static func statsHappy() async throws {
        let data = try loadFixture("stats")
        MockURLProtocol.handler = { req in
            try expectEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer testtoken")
            try expect(req.url?.path.hasSuffix("/stats") == true)
            return (okResponse(for: req.url!), data)
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        let stats = try await client.stats()
        try expectClose(stats.cpu.percentTotal, 12.5)
    }

    static func processesHappy() async throws {
        let data = try loadFixture("processes")
        MockURLProtocol.handler = { req in
            try expect(req.url?.query?.contains("limit=10") == true)
            try expect(req.url?.query?.contains("include_full_cmdline=false") == true)
            return (okResponse(for: req.url!), data)
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        let resp = try await client.processes(limit: 10)
        try expectEqual(resp.totalCount, 423)
    }

    static func portsHappy() async throws {
        let data = try loadFixture("ports")
        MockURLProtocol.handler = { req in (okResponse(for: req.url!), data) }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        let resp = try await client.ports()
        try expectEqual(resp.ports.count, 4)
    }

    static func sshSessionsHappy() async throws {
        let data = try loadFixture("ssh-sessions")
        MockURLProtocol.handler = { req in (okResponse(for: req.url!), data) }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        let resp = try await client.sshSessions()
        try expectEqual(resp.sessions.count, 2)
    }

    static func tmuxSessionsHappy() async throws {
        let data = try loadFixture("tmux-sessions")
        MockURLProtocol.handler = { req in (okResponse(for: req.url!), data) }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        let resp = try await client.tmuxSessions()
        try expectEqual(resp.sessions.count, 2)
    }

    // MARK: - error paths

    static func unauthorizedReturns401() async throws {
        MockURLProtocol.handler = { req in
            (okResponse(for: req.url!, code: 401),
             Data(#"{"detail":"bad token"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        do {
            _ = try await client.stats()
            throw TestFailure.assertion("expected error", #file, #line)
        } catch let err as StudioClientError {
            if case .unauthorized = err { return }
            throw TestFailure.assertion("wrong error: \(err)", #file, #line)
        }
    }

    static func serverErrorMaps() async throws {
        MockURLProtocol.handler = { req in
            (okResponse(for: req.url!, code: 500),
             Data(#"{"detail":"boom"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        do {
            _ = try await client.stats()
            throw TestFailure.assertion("expected error", #file, #line)
        } catch let err as StudioClientError {
            if case .serverError(500, _) = err { return }
            throw TestFailure.assertion("wrong error: \(err)", #file, #line)
        }
    }

    static func connectionRefusedMapsToConnectionFailed() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        do {
            _ = try await client.stats()
            throw TestFailure.assertion("expected error", #file, #line)
        } catch let err as StudioClientError {
            if case .connectionFailed = err { return }
            throw TestFailure.assertion("wrong error: \(err)", #file, #line)
        }
    }

    static func timeoutMaps() async throws {
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        do {
            _ = try await client.stats()
            throw TestFailure.assertion("expected error", #file, #line)
        } catch let err as StudioClientError {
            if case .timeout = err { return }
            throw TestFailure.assertion("wrong error: \(err)", #file, #line)
        }
    }

    static func notFoundOnKill() async throws {
        MockURLProtocol.handler = { req in
            (okResponse(for: req.url!, code: 404),
             Data(#"{"detail":"pid not found"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        do {
            _ = try await client.kill(pid: 999999)
            throw TestFailure.assertion("expected error", #file, #line)
        } catch let err as StudioClientError {
            if case .notFound(let msg) = err {
                try expect(msg.contains("pid"))
                return
            }
            throw TestFailure.assertion("wrong error: \(err)", #file, #line)
        }
    }

    static func killPostsCorrectly() async throws {
        MockURLProtocol.handler = { req in
            try expectEqual(req.httpMethod, "POST")
            try expect(req.url?.path.hasSuffix("/kill") == true)
            try expectEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (okResponse(for: req.url!),
                    Data(#"{"pid":123,"signal":15,"process_name":"foo","sent_at":"2026-04-15T18:00:00Z"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        _ = try await client.kill(pid: 123, signal: 15)
    }

    static func tmuxNewPostsCorrectly() async throws {
        MockURLProtocol.handler = { req in
            try expectEqual(req.httpMethod, "POST")
            try expect(req.url?.path.hasSuffix("/tmux/new") == true)
            return (okResponse(for: req.url!),
                    Data(#"{"name":"foo","created":true,"exists":false}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        _ = try await client.tmuxNew(name: "foo")
    }

    static func sshKickPostsCorrectly() async throws {
        MockURLProtocol.handler = { req in
            try expectEqual(req.httpMethod, "POST")
            try expect(req.url?.path.hasSuffix("/ssh/kick") == true)
            return (okResponse(for: req.url!),
                    Data(#"{"session":{"pid":8822,"user":"x","source_ip":"100.64.1.20","source_port":52812,"tailscale_peer":null,"tty":null,"started_at":"2026-04-15T18:00:00Z","idle_seconds":null},"sent_at":"2026-04-15T18:30:00Z"}"#.utf8))
        }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient()
        _ = try await client.sshKick(pid: 8822)
    }
}
