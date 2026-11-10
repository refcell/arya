import AryaCore
import Foundation

/// The records a ``FakeBindingServer`` serves: `{"v":1,"history":[HistoryItem…]}`.
public struct FakeBindingData: Sendable, Hashable, Codable {
    public var v: Int
    public var history: [HistoryItem]

    public init(v: Int = 1, history: [HistoryItem]) {
        self.v = v
        self.history = history
    }

    public static func load(from url: URL) throws -> FakeBindingData {
        try JSONDecoder().decode(FakeBindingData.self, from: Data(contentsOf: url))
    }

    enum CodingKeys: String, CodingKey {
        case v, history
    }
}

/// A deterministic MCP binding server over newline-delimited JSON-RPC, for tests, the demo, and
/// importer development. It serves three read tools from ``FakeBindingData``: `history` (the
/// convention), `get` (`{id}` → the record), and `search` (`{query}` → `{items}` of records
/// whose JSON contains the query, ignoring case). `arya-fake-adapter --binding <file>` runs it.
public actor FakeBindingServer {
    public static let protocolVersion = "2025-06-18"
    private let data: FakeBindingData

    public init(data: FakeBindingData) {
        self.data = data
    }

    /// Serves until the client closes the connection.
    public func serve(_ endpoint: any AdapterEndpoint) async {
        for await line in endpoint.incoming {
            let reply: RPCMessage?
            do {
                reply = handle(try LineCodec.decode(line))
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
    public func handle(_ message: RPCMessage) -> RPCMessage? {
        guard case .request(let request) = message else { return nil }
        do {
            return .response(RPCResponse(id: request.id, result: try answer(request)))
        } catch let error as RPCError {
            return .response(RPCResponse(id: request.id, error: error))
        } catch {
            let error = RPCError(code: RPCErrorCode.internalError, message: "\(error)")
            return .response(RPCResponse(id: request.id, error: error))
        }
    }

    private func answer(_ request: RPCRequest) throws -> JSONValue {
        switch request.method {
        case "initialize":
            return [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "arya-fake-binding", "version": "0.1.0"],
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            let name = request.params?["name"]?.stringValue ?? ""
            return try call(name, request.params?["arguments"] ?? [:])
        default:
            throw RPCError(
                code: RPCErrorCode.methodNotFound, message: "unknown method \(request.method)")
        }
    }

    private func call(_ name: String, _ arguments: JSONValue) throws -> JSONValue {
        switch name {
        case BindingHistory.tool:
            let params: HistoryListParams
            do {
                params = try arguments.decode(HistoryListParams.self)
            } catch {
                return Self.result(.string("invalid history arguments: \(error)"), isError: true)
            }
            return Self.result(
                try JSONValue(encoding: BindingHistory.page(data.history, params)), isError: false)
        case "get":
            let id = arguments["id"]?.stringValue ?? ""
            guard let item = data.history.first(where: { $0.id == id }) else {
                return Self.result(.string("no record \(id)"), isError: true)
            }
            return Self.result(item.record ?? ["id": .string(id)], isError: false)
        case "search":
            let query = (arguments["query"]?.stringValue ?? "").lowercased()
            let found = data.history.compactMap(\.record).filter { record in
                String(decoding: LineCodec.encodeJSON(record), as: UTF8.self).lowercased()
                    .contains(query)
            }
            return Self.result(["items": .array(found)], isError: false)
        default:
            throw RPCError(code: RPCErrorCode.invalidParams, message: "unknown tool \(name)")
        }
    }

    static let tools: JSONValue = [
        [
            "name": .string(BindingHistory.tool),
            "description": "Past records with what a person did with each, oldest first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "since": ["type": "string"], "until": ["type": "string"],
                    "cursor": ["type": "string"], "limit": ["type": "integer"],
                ],
            ],
        ],
        [
            "name": "get", "description": "One record by id.",
            "inputSchema": [
                "type": "object", "properties": ["id": ["type": "string"]], "required": ["id"],
            ],
        ],
        [
            "name": "search", "description": "Records whose content contains the query.",
            "inputSchema": [
                "type": "object", "properties": ["query": ["type": "string"]],
                "required": ["query"],
            ],
        ],
    ]

    /// A `tools/call` result with `output` as structured content and as JSON text.
    static func result(_ output: JSONValue, isError: Bool) -> JSONValue {
        let text =
            output.stringValue ?? String(decoding: LineCodec.encodeJSON(output), as: UTF8.self)
        return [
            "content": [["type": "text", "text": .string(text)]],
            "structuredContent": output, "isError": .bool(isError),
        ]
    }
}
