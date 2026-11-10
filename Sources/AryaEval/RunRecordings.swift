import AryaAdapters
import AryaCore
import AryaRuntime

/// Every tool read a run made, as a case's recorded tool results: the binding proxy's
/// `run.tool.call`/`run.tool.result` pairs, then reads the adapter reported itself as
/// `tool_call`/`tool_result` run events (an agent with its own tools, or the fake adapter).
/// Rehearsal marks any adapter-reported call without a recording as a leak, so a case built
/// from a live run needs both.
enum RunRecordings {
    static func from(_ events: [RuntimeEvent], run: RunID) throws -> [RecordedToolResult] {
        var recorded = try ToolRecordings.from(events, run: run)
        for item in adapterReported(events, run: run) where !recorded.contains(item) {
            recorded.append(item)
        }
        return recorded
    }

    /// `tool_call` events paired with their `tool_result` by id, in call order. Calls without
    /// a result are skipped.
    static func adapterReported(_ events: [RuntimeEvent], run: RunID) -> [RecordedToolResult] {
        var calls: [(id: String, tool: String, input: JSONValue)] = []
        var results: [String: (output: JSONValue, isError: Bool)] = [:]
        for event in events where event.draft.run == run && event.type == RunEventType.adapterEvent
        {
            guard let message = event.payload["message"],
                message["method"]?.stringValue == RPCMethod.runEvent,
                let body = message["params"]?["event"],
                let id = body["id"]?.stringValue
            else { continue }
            switch body["kind"]?.stringValue {
            case "tool_call":
                guard let tool = body["tool"]?.stringValue else { continue }
                calls.append((id, tool, body["input"] ?? .object([:])))
            case "tool_result":
                results[id] = (body["output"] ?? .null, body["isError"]?.boolValue ?? false)
            default:
                continue
            }
        }
        return calls.compactMap { call in
            results[call.id].map {
                RecordedToolResult(
                    tool: call.tool, input: call.input, output: $0.output, isError: $0.isError)
            }
        }
    }
}
