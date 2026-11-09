import AryaAdapters
import AryaCore
import AryaLedger
import Foundation

// The binding proxy (ARCHITECTURE.md "Bindings"): one stdio MCP server per binding that a
// harness talks to instead of the real system. It exposes only the binding's `read` tools,
// records each call as `run.tool.call` and `run.tool.result`, and in rehearsal and replay
// answers from recorded results instead of the live system. Write tools are never exposed;
// writes come back as proposed actions.

/// The live MCP server behind a binding.
public protocol ToolUpstream: Sendable {
    /// The server's tool descriptors (`tools/list` entries: `name`, `description`,
    /// `inputSchema`).
    func listTools() async throws -> [JSONValue]
    /// Calls one tool; returns the `tools/call` result object.
    func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue
}

/// Where a proxy's answers come from.
public enum ToolSource: Sendable {
    /// The live server.
    case live(any ToolUpstream)
    /// Recorded results (rehearsal and replay). A call without a recording is a leak.
    case recorded([RecordedToolResult])
}

/// Where a proxy records its calls.
public struct ToolCallRecorder: Sendable {
    /// The sink.
    public var sink: any EventSink
    /// The run's steward.
    public var steward: StewardID
    /// The run.
    public var run: RunID

    /// Creates a recorder.
    public init(sink: any EventSink, steward: StewardID, run: RunID) {
        self.sink = sink
        self.steward = steward
        self.run = run
    }
}

/// One binding's MCP server.
public actor BindingProxy {
    /// MCP protocol version the proxy speaks.
    public static let protocolVersion = "2025-06-18"

    private let binding: CharterBinding
    private let source: ToolSource
    private let recorder: ToolCallRecorder?
    /// True once a recorded-source call had no recording.
    public private(set) var leak = false

    /// Creates a proxy for `binding`.
    public init(binding: CharterBinding, source: ToolSource, recorder: ToolCallRecorder?) {
        self.binding = binding
        self.source = source
        self.recorder = recorder
    }

    /// Serves newline-delimited JSON-RPC from `input`, writing replies with `output`, until
    /// `input` ends.
    public func serve(
        _ input: AsyncStream<Data>, output: @escaping @Sendable (Data) async -> Void
    ) async {
        var splitter = LineSplitter()
        for await chunk in input {
            for line in splitter.append(chunk) {
                // A line that does not parse has no id to answer; it is dropped.
                guard let message = try? LineCodec.decode(line),
                    let reply = try? await handle(message)
                else { continue }
                await output(LineCodec.encode(reply))
            }
        }
    }

    /// Answers one message; notifications and responses get no reply.
    public func handle(_ message: RPCMessage) async throws -> RPCMessage? {
        guard case .request(let request) = message else { return nil }
        do {
            let result = try await answer(request)
            return .response(RPCResponse(id: request.id, result: result))
        } catch let error as RPCError {
            return .response(RPCResponse(id: request.id, error: error))
        }
    }

    private func answer(_ request: RPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            return [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string("arya-binding-\(binding.id)"), "version": "0.1.0"],
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(try await tools())]
        case "tools/call":
            return try await call(request)
        default:
            throw RPCError(
                code: RPCErrorCode.methodNotFound, message: "unknown method \(request.method)")
        }
    }

    /// The read tools: the upstream's descriptors for names in `binding.read`, or bare
    /// descriptors when answering from recordings.
    private func tools() async throws -> [JSONValue] {
        let read = Set(binding.read)
        switch source {
        case .live(let upstream):
            let all = try await upstream.listTools()
            return all.filter { $0["name"]?.stringValue.map(read.contains) ?? false }
        case .recorded:
            return binding.read.map {
                ["name": .string($0), "inputSchema": ["type": "object"]]
            }
        }
    }

    private func call(_ request: RPCRequest) async throws -> JSONValue {
        guard let name = request.params?["name"]?.stringValue else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "tools/call needs a name")
        }
        guard binding.read.contains(name) else {
            throw RPCError(
                code: RPCErrorCode.invalidParams,
                message: "\(binding.id).\(name) is not a read tool of this binding")
        }
        let input = request.params?["arguments"] ?? [:]
        let id = "\(binding.id):\(request.id)"
        try await record(RunToolCall(id: id, binding: binding.id, tool: name, input: input))
        let result: JSONValue
        let output: JSONValue
        let isError: Bool
        switch source {
        case .live(let upstream):
            do {
                result = try await upstream.call(name, arguments: input)
                isError = result["isError"]?.boolValue ?? false
                output = result["structuredContent"] ?? result["content"] ?? .null
            } catch {
                (output, isError) = (.string("\(error)"), true)
                result = Self.result(output, isError: true)
            }
        case .recorded(let recordings):
            if let hit = recordings.first(where: { matches($0, name, input) }) {
                (output, isError) = (hit.output, hit.isError)
            } else {
                leak = true
                (output, isError) = (.string("no recorded result for \(binding.id).\(name)"), true)
            }
            result = Self.result(output, isError: isError)
        }
        try await record(RunToolResult(id: id, output: output, isError: isError))
        return result
    }

    /// A recording answers a call when its tool is `<binding>.<tool>` (or the bare tool name)
    /// and its input is equal.
    private func matches(_ recording: RecordedToolResult, _ name: String, _ input: JSONValue)
        -> Bool
    {
        (recording.tool == "\(binding.id).\(name)" || recording.tool == name)
            && recording.input == input
    }

    /// A `tools/call` result carrying `output` as structured content and as JSON text.
    static func result(_ output: JSONValue, isError: Bool) -> JSONValue {
        let text =
            output.stringValue ?? String(decoding: LineCodec.encodeJSON(output), as: UTF8.self)
        return [
            "content": [["type": "text", "text": .string(text)]],
            "structuredContent": output, "isError": .bool(isError),
        ]
    }

    private func record<P: EventPayload>(_ payload: P) async throws {
        guard let recorder else { return }
        _ = try await recorder.sink.append(
            RuntimeEventDraft(
                type: P.type.rawValue, steward: recorder.steward, run: recorder.run,
                actor: .system, payload: try Payload.encode(payload)))
    }
}
