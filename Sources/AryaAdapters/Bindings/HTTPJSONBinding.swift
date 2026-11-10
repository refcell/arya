import AryaCore
import Foundation

/// Sends one HTTP request. The live one is ``URLSessionHTTPTransport``; tests answer from
/// fixtures so they never touch the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The live ``HTTPTransport``. It never follows redirects, so the token is only ever sent to
/// the configured host; a redirect comes back as its own 3xx response.
public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else {
            throw BindingToolError("the server did not answer over HTTP")
        }
        return (data, http)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// How to reach a JSON-over-HTTP service.
public struct HTTPJSONConfig: Sendable, Hashable {
    /// The service root; every path below is relative to it.
    public var baseURL: URL
    /// Sent as `Authorization: Bearer <token>`; read from ``BindingCredential/variable``.
    public var token: String?
    /// Action kinds served as tools that `POST /actions`.
    public var actions: [String]
    /// Per-request time limit.
    public var timeout: TimeInterval

    public init(
        baseURL: URL, token: String? = nil, actions: [String] = [], timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.token = token
        self.actions = actions
        self.timeout = timeout
    }

    /// Why `baseURL` is unsafe to send a token to, or nil when it is fine: it must be `https`
    /// (plain `http` only for this machine) and must not carry a user name or password.
    public var problem: String? {
        guard let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host?.lowercased()
        else { return "the base URL needs a scheme and a host" }
        if baseURL.user != nil || baseURL.password != nil {
            return "the base URL must not contain credentials; arya passes the token separately"
        }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        if scheme == "https" || (scheme == "http" && local) { return nil }
        return "the base URL must use https (plain http is allowed only for localhost)"
    }
}

/// A binding over any service that speaks plain JSON over HTTP (docs/PROTOCOL.md, "HTTP JSON
/// binding"). Each tool is one request below the base URL:
///
/// | tool | request |
/// | --- | --- |
/// | `history` | `GET /history?since&until&cursor&limit` → a `history` page |
/// | `outcome` | `GET /outcomes?target&action&since` → an `outcome` result |
/// | `directory` | `GET /directory?role` → a `directory` result |
/// | `process` | `GET /process` → a `process` result |
/// | `list` | `GET /items?query&cursor` → any JSON |
/// | `get` | `GET /items/<id>` → any JSON |
/// | each configured action kind | `POST /actions` with `{kind, target, params}` → any JSON |
///
/// Convention results are checked against their types, so a service that answers in another
/// shape fails loudly instead of feeding arya bad data.
public struct HTTPJSONBindingSource: BindingSource {
    public let config: HTTPJSONConfig
    private let transport: any HTTPTransport

    public init(config: HTTPJSONConfig, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.config = config
        self.transport = transport
    }

    public var serverName: String { "arya-http-json-binding" }

    static let readTools = [
        BindingTools.history, BindingTools.outcome, BindingTools.directory, BindingTools.process,
        "list", BindingTools.get,
    ]

    public func tools() -> [JSONValue] {
        let reads = Self.readTools.map { name -> JSONValue in
            name == "list"
                ? [
                    "name": "list", "description": "Records, optionally matching a query.",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["query": ["type": "string"], "cursor": ["type": "string"]],
                    ],
                ]
                : BindingTools.descriptor(name)
        }
        let actions = config.actions.map { kind -> JSONValue in
            [
                "name": .string(kind), "description": .string("Carries out a \(kind) action."),
                "inputSchema": ["type": "object", "properties": ["target": ["type": "string"]]],
            ]
        }
        return reads + actions
    }

    public func call(_ tool: String, _ arguments: JSONValue) async throws -> JSONValue {
        if let problem = config.problem { throw BindingToolError(problem) }
        switch tool {
        case BindingTools.history:
            let params = try BindingServer.decode(HistoryListParams.self, arguments, tool: tool)
            let query = [
                ("since", params.since), ("until", params.until), ("cursor", params.cursor),
                ("limit", params.limit.map(String.init)),
            ]
            return try await get("history", query, as: HistoryListResult.self)
        case BindingTools.outcome:
            let params = try BindingServer.decode(OutcomeCheckParams.self, arguments, tool: tool)
            let query = [
                ("target", Optional(params.target)), ("action", params.action),
                ("since", params.since),
            ]
            return try await get("outcomes", query, as: OutcomeCheckResult.self)
        case BindingTools.directory:
            let params = try BindingServer.decode(DirectoryListParams.self, arguments, tool: tool)
            return try await get("directory", [("role", params.role)], as: DirectoryListResult.self)
        case BindingTools.process:
            return try await get("process", [], as: ProcessListResult.self)
        case "list":
            let query = [
                ("query", arguments["query"]?.stringValue),
                ("cursor", arguments["cursor"]?.stringValue),
            ]
            return try await send(request("GET", "items", query))
        case BindingTools.get:
            guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
                throw BindingToolError("get needs an id")
            }
            return try await send(request("GET", "items/\(Self.segment(id))", []))
        default:
            guard config.actions.contains(tool) else { throw BindingServer.unknownTool(tool) }
            var params = arguments.objectValue ?? [:]
            let target = params.removeValue(forKey: "target")
            var body: [String: JSONValue] = ["kind": .string(tool), "params": .object(params)]
            if let target { body["target"] = target }
            var post = try request("POST", "actions", [])
            post.httpBody = LineCodec.encodeJSON(.object(body))
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return try await send(post)
        }
    }

    // MARK: Requests

    private func get<T: Codable>(
        _ path: String, _ query: [(String, String?)], as type: T.Type
    ) async throws -> JSONValue {
        let value = try await send(request("GET", path, query))
        do {
            return try JSONValue(encoding: try value.decode(type))
        } catch {
            throw BindingToolError("GET /\(path) answered in an unexpected shape: \(error)")
        }
    }

    func request(_ method: String, _ path: String, _ query: [(String, String?)]) throws
        -> URLRequest
    {
        var base = config.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: "\(base)/\(path)")
        let items = query.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        if !items.isEmpty { components?.queryItems = items }
        guard let url = components?.url else {
            throw BindingToolError("cannot build a URL for /\(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = config.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        let label = "\(request.httpMethod ?? "GET") /\(request.url?.path ?? "")"
            .replacingOccurrences(of: "//", with: "/")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as BindingToolError {
            throw error
        } catch {
            throw BindingToolError("\(label) failed: \(error.localizedDescription)")
        }
        switch response.statusCode {
        case 200..<300:
            if data.isEmpty { return [:] }
            do {
                return try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw BindingToolError("\(label) did not answer with JSON")
            }
        case 401, 403:
            throw BindingToolError(
                "\(label) was refused (\(response.statusCode)); check the connection's token")
        case 300..<400:
            throw BindingToolError(
                "\(label) redirected (\(response.statusCode)); arya does not follow redirects, "
                    + "so set the base URL to where the service lives")
        default:
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            throw BindingToolError("\(label) answered \(response.statusCode): \(body)")
        }
    }

    /// `id` as one path segment: `/`, `?`, `#`, and `%` are escaped.
    static func segment(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }
}
