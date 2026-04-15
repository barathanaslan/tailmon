// StudioClient.swift -- URLSession-based HTTP client for the collector.
//
// Mirrors the Python `studio_cli.client.StudioClient` behavior:
// - Sends `Authorization: Bearer <token>` on every request
// - Maps HTTP failures to a typed `StudioClientError`
// - Tests inject a fake network layer via a custom URLSessionConfiguration
//   that registers a `URLProtocol` subclass

import Foundation

public enum StudioClientError: Error, CustomStringConvertible, Equatable {
    case connectionFailed(String)
    case timeout
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case serverError(Int, String)
    case badStatus(Int, String)
    case nonJSON(String)
    case decode(String)
    case unknown(String)

    public var description: String {
        switch self {
        case .connectionFailed(let s): return "cannot reach collector: \(s)"
        case .timeout: return "timed out talking to collector"
        case .unauthorized: return "collector rejected token (401)"
        case .forbidden(let s): return "collector refused request (403): \(s)"
        case .notFound(let s): return "collector returned 404: \(s)"
        case .serverError(let code, let s): return "collector internal error (\(code)): \(s)"
        case .badStatus(let code, let s): return "collector returned \(code): \(s)"
        case .nonJSON(let s): return "collector returned non-JSON: \(s)"
        case .decode(let s): return "collector returned malformed JSON: \(s)"
        case .unknown(let s): return "unknown error: \(s)"
        }
    }

    /// Short banner-friendly label for the popover header.
    public var shortLabel: String {
        switch self {
        case .connectionFailed: return "cannot reach collector"
        case .timeout: return "collector timed out"
        case .unauthorized: return "token rejected"
        case .forbidden: return "request forbidden"
        case .notFound: return "not found"
        case .serverError: return "collector error"
        case .badStatus: return "HTTP error"
        case .nonJSON, .decode: return "bad response"
        case .unknown: return "unknown error"
        }
    }
}

public actor StudioClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession
    private let decoder: JSONDecoder = StudioJSON.makeDecoder()
    private let encoder: JSONEncoder = StudioJSON.makeEncoder()

    public init(baseURL: URL, token: String?, timeout: TimeInterval, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        if let session = session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = timeout
            cfg.timeoutIntervalForResource = timeout
            cfg.waitsForConnectivity = false
            cfg.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - read endpoints

    public func health() async throws -> HealthResponse {
        try await get("/health", authenticated: false)
    }

    public func stats() async throws -> StatsResponse {
        try await get("/stats")
    }

    public func processes(limit: Int = 10) async throws -> ProcessListResponse {
        try await get("/processes", query: ["limit": "\(limit)", "include_full_cmdline": "false"])
    }

    public func ports() async throws -> PortListResponse {
        try await get("/ports")
    }

    public func sshSessions() async throws -> SSHSessionListResponse {
        try await get("/ssh/sessions")
    }

    public func tmuxSessions() async throws -> TmuxSessionListResponse {
        try await get("/tmux/sessions")
    }

    // MARK: - write endpoints

    struct KillBody: Encodable {
        let pid: Int
        let signal: Int
    }
    struct KickBody: Encodable {
        let pid: Int
    }
    struct TmuxNewBody: Encodable {
        let name: String
    }

    @discardableResult
    public func kill(pid: Int, signal: Int = 15) async throws -> Data {
        try await postRaw("/kill", body: KillBody(pid: pid, signal: signal))
    }

    @discardableResult
    public func sshKick(pid: Int) async throws -> Data {
        try await postRaw("/ssh/kick", body: KickBody(pid: pid))
    }

    @discardableResult
    public func tmuxNew(name: String) async throws -> Data {
        try await postRaw("/tmux/new", body: TmuxNewBody(name: name))
    }

    // MARK: - internals

    private func makeRequest(_ path: String, method: String, query: [String: String]? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if let query = query, !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let url = components?.url ?? baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: request)
            guard let http = resp as? HTTPURLResponse else {
                throw StudioClientError.unknown("non-HTTP response")
            }
            return (data, http)
        } catch let err as URLError {
            switch err.code {
            case .timedOut:
                throw StudioClientError.timeout
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .cannotLoadFromNetwork,
                 .resourceUnavailable:
                throw StudioClientError.connectionFailed(err.localizedDescription)
            default:
                throw StudioClientError.connectionFailed(err.localizedDescription)
            }
        } catch let err as StudioClientError {
            throw err
        } catch {
            throw StudioClientError.unknown(error.localizedDescription)
        }
    }

    private func decodeOrThrow<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw StudioClientError.decode("\(error): \(preview)")
        }
    }

    private func handleStatus(_ http: HTTPURLResponse, data: Data) throws {
        let code = http.statusCode
        if (200..<300).contains(code) { return }
        let detail = extractDetail(data) ?? (String(data: data.prefix(200), encoding: .utf8) ?? "")
        switch code {
        case 401:
            throw StudioClientError.unauthorized
        case 403:
            throw StudioClientError.forbidden(detail)
        case 404:
            throw StudioClientError.notFound(detail)
        case 500...599:
            throw StudioClientError.serverError(code, detail)
        default:
            throw StudioClientError.badStatus(code, detail)
        }
    }

    private func extractDetail(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let s = obj["detail"] as? String { return s }
        if let s = obj["error"] as? String { return s }
        return nil
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]? = nil, authenticated: Bool = true) async throws -> T {
        let req = makeRequest(path, method: "GET", query: query)
        let (data, http) = try await perform(req)
        try handleStatus(http, data: data)
        return try decodeOrThrow(data)
    }

    private func postRaw<B: Encodable>(_ path: String, body: B) async throws -> Data {
        var req = makeRequest(path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let (data, http) = try await perform(req)
        try handleStatus(http, data: data)
        return data
    }
}
