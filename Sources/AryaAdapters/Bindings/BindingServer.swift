import AryaCore
import Foundation

/// What a binding server serves: its name, its tools, and how to call them.
public protocol BindingSource: Sendable {
    /// The `serverInfo.name` it reports.
    var serverName: String { get }
    /// The `tools/list` entries.
    func tools() async throws -> [JSONValue]
    /// Calls a tool and returns its output. Throws ``BindingToolError`` for a failure the
    /// caller should read (sent as an `isError` result) and `RPCError` for an unknown tool.
    func call(_ tool: String, _ arguments: JSONValue) async throws -> JSONValue
}

/// A tool failure reported to the caller as an `isError` result with this message.
public struct BindingToolError: Error, Sendable, Hashable {
    public var message: String

    public init(_ message: String) { self.message = message }
}

/// The environment variable a binding server reads its secret from. arya sets it from the
/// connection's Keychain entry when it starts the server; the secret is never an argument.
public enum BindingCredential {
    public static let variable = "ARYA_CREDENTIAL"
}

/// An MCP server over newline-delimited JSON-RPC for any ``BindingSource``: `initialize`,
/// `ping`, `tools/list`, and `tools/call`.
public actor BindingServer {
    public static let protocolVersion = "2025-06-18"
    private let source: any BindingSource

    public init(source: any BindingSource) {
        self.source = source
    }

    /// Serves until the client closes the connection.
    public func serve(_ endpoint: any AdapterEndpoint) async {
        for await line in endpoint.incoming {
            let reply: RPCMessage?
            do {
                reply = await handle(try LineCodec.decode(line))
            } catch {
                let reply: JSONValue = [
                    "jsonrpc": "2.0", "id": nil,
                    "error": ["code": .int(Int64(error.code)), "message": .string(error.message)],
                ]
                var bytes = LineCodec.encodeJSON(reply)
                bytes.append(0x0A)
                await endpoint.write(bytes)
                continue
            }
            if let reply { await endpoint.write(LineCodec.encode(reply)) }
        }
        await endpoint.close(.exited(0))
    }

    /// The reply to one message; notifications and responses get none.
    public func handle(_ message: RPCMessage) async -> RPCMessage? {
        guard case .request(let request) = message else { return nil }
        do {
            return .response(RPCResponse(id: request.id, result: try await answer(request)))
        } catch let error as RPCError {
            return .response(RPCResponse(id: request.id, error: error))
        } catch {
            let error = RPCError(code: RPCErrorCode.internalError, message: "\(error)")
            return .response(RPCResponse(id: request.id, error: error))
        }
    }

    private func answer(_ request: RPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            return [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(source.serverName), "version": "0.1.0"],
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(try await source.tools())]
        case "tools/call":
            guard let name = request.params?["name"]?.stringValue else {
                throw RPCError(code: RPCErrorCode.invalidParams, message: "tools/call needs a name")
            }
            do {
                let output = try await source.call(name, request.params?["arguments"] ?? [:])
                return Self.result(output, isError: false)
            } catch let error as BindingToolError {
                return Self.result(.string(error.message), isError: true)
            }
        default:
            throw RPCError(
                code: RPCErrorCode.methodNotFound, message: "unknown method \(request.method)")
        }
    }

    /// A `tools/call` result with `output` as structured content and as JSON text.
    public static func result(_ output: JSONValue, isError: Bool) -> JSONValue {
        let text =
            output.stringValue ?? String(decoding: LineCodec.encodeJSON(output), as: UTF8.self)
        return [
            "content": [["type": "text", "text": .string(text)]],
            "structuredContent": output, "isError": .bool(isError),
        ]
    }

    /// Decodes tool arguments, reporting bad ones as a tool error.
    static func decode<T: Decodable>(_ type: T.Type, _ arguments: JSONValue, tool: String)
        throws -> T
    {
        do {
            return try arguments.decode(type)
        } catch {
            throw BindingToolError("invalid \(tool) arguments: \(error)")
        }
    }

    static func unknownTool(_ name: String) -> RPCError {
        RPCError(code: RPCErrorCode.invalidParams, message: "unknown tool \(name)")
    }
}

/// Answers for the convention tools from records held in memory; the fake and folder
/// bindings share it.
struct RecordSet: Sendable {
    var history: [HistoryItem]
    var outcomes: [OutcomeCheckResult]
    var directory: [DirectoryPerson]?
    var process: ProcessListResult?

    /// The tools these records can answer.
    var toolNames: [String] {
        var names: [String] = []
        if !history.isEmpty { names.append(BindingTools.history) }
        if !history.isEmpty || !outcomes.isEmpty { names.append(BindingTools.outcome) }
        if directory != nil { names.append(BindingTools.directory) }
        if process != nil { names.append(BindingTools.process) }
        if !history.isEmpty { names += [BindingTools.get, BindingTools.search] }
        return names
    }

    func call(_ name: String, _ arguments: JSONValue) throws -> JSONValue {
        guard toolNames.contains(name) else { throw BindingServer.unknownTool(name) }
        switch name {
        case BindingTools.history:
            let params = try BindingServer.decode(HistoryListParams.self, arguments, tool: name)
            return try JSONValue(encoding: BindingHistory.page(history, params))
        case BindingTools.outcome:
            let params = try BindingServer.decode(OutcomeCheckParams.self, arguments, tool: name)
            return try JSONValue(encoding: outcome(params))
        case BindingTools.directory:
            let params = try BindingServer.decode(DirectoryListParams.self, arguments, tool: name)
            let people = (directory ?? []).filter { person in
                params.role.map { person.roles.contains($0) } ?? true
            }
            return try JSONValue(encoding: DirectoryListResult(people: people))
        case BindingTools.process:
            return try JSONValue(encoding: process ?? ProcessListResult())
        case BindingTools.get:
            let id = arguments["id"]?.stringValue ?? ""
            guard let item = history.first(where: { $0.id == id }) else {
                throw BindingToolError("no record \(id)")
            }
            return item.record ?? ["id": .string(id)]
        default:
            let query = (arguments["query"]?.stringValue ?? "").lowercased()
            let found = history.compactMap(\.record).filter { record in
                String(decoding: LineCodec.encodeJSON(record), as: UTF8.self).lowercased()
                    .contains(query)
            }
            return ["items": .array(found)]
        }
    }

    /// An explicit outcome for the target, else the outcome of the history item a person's
    /// action targeted (or whose id the target ends with), else `unknown`.
    func outcome(_ params: OutcomeCheckParams) -> OutcomeCheckResult {
        if let known = outcomes.last(where: { $0.target == params.target }) { return known }
        let item = history.first { item in
            item.actions.contains { $0.target == params.target }
                || params.target.hasSuffix(":\(item.id)")
        }
        guard let item, let outcome = item.outcome else {
            return OutcomeCheckResult(target: params.target, status: "unknown")
        }
        return OutcomeCheckResult(
            target: params.target, status: outcome.status, at: outcome.at, note: outcome.note)
    }
}
