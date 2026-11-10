import AryaCore
import Foundation

/// Extracts results and events from a command-line agent's output (exec profiles).
public enum ExecOutput {
    /// `text` parsing: the content of the last fenced block whose info string is `json`,
    /// decoded. `nil` when there is no such block or it is not valid JSON.
    public static func lastJSONBlock(in text: String) -> JSONValue? {
        var current: [Substring]?
        var last: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if current == nil {
                if trimmed.hasPrefix("```"), trimmed.dropFirst(3).lowercased() == "json" {
                    current = []
                }
            } else if trimmed == "```" {
                last = current
                current = nil
            } else {
                current?.append(line)
            }
        }
        guard let block = last else { return nil }
        let data = Data(block.joined(separator: "\n").utf8)
        return try? CanonicalJSON.decode(JSONValue.self, from: data)
    }

    /// What one `jsonl` output line means.
    public enum JSONLine: Sendable, Hashable {
        /// An object with a `result` key; the last one is the run's result.
        case result(JSONValue)
        /// An object that is a valid ``RunEvent``.
        case event(RunEvent)
        /// An object with a `cost` key holding token and micro-dollar totals so far; the last
        /// one answers `run/cost`.
        case cost(CostResult)
        /// Anything else: not JSON, not an object, or an unknown shape. Kept as text.
        case other(String)
    }

    /// `jsonl` parsing of one line.
    public static func parse(jsonLine line: String) -> JSONLine {
        let data = Data(line.utf8)
        guard let value = try? CanonicalJSON.decode(JSONValue.self, from: data),
            case .object(let members) = value
        else { return .other(line) }
        if let result = members["result"] { return .result(result) }
        if let cost = members["cost"], let totals = try? cost.decode(CostResult.self) {
            return .cost(totals)
        }
        if members["kind"]?.stringValue != nil,
            let event = try? CanonicalJSON.decode(RunEvent.self, from: data)
        {
            return .event(event)
        }
        return .other(line)
    }
}

extension ExecOutput {
    /// What one `stream-json` output line means.
    public enum StreamJSONLine: Sendable, Hashable {
        /// An `assistant` or `user` message, as run events (text, thinking, tool use, results).
        case events([RunEvent])
        /// The final `result` line: the reply text, whether the agent reported an error, and
        /// the run's cost (input counts include cache reads and writes).
        case final(text: String, isError: Bool, cost: CostResult)
        /// A partial-message `stream_event` (with `--include-partial-messages`): its `event`.
        case partial(JSONValue)
        /// Anything else (`system` lines, unknown types, non-JSON).
        case other
    }

    /// Turns partial-message stream events into a `compose` step per text block: a
    /// `tool_call` when the block starts, `tool_output` per text delta, and a `tool_result`
    /// when it stops. The complete message still arrives as its own `message` event.
    public struct StreamJSONPartials: Sendable {
        private var message = ""
        private var count = 0
        private var open: [Int64: (id: String, characters: Int)] = [:]

        public init() {}

        public mutating func events(for event: JSONValue) -> [RunEvent] {
            let index = event["index"]?.intValue ?? 0
            switch event["type"]?.stringValue {
            case "message_start":
                count += 1
                message = event["message"]?["id"]?.stringValue ?? "message-\(count)"
                return []
            case "content_block_start":
                guard event["content_block"]?["type"] == "text" else { return [] }
                let id = "\(message.isEmpty ? "message" : message):\(index)"
                open[index] = (id, 0)
                return [RunEvent(.toolCall(id: id, tool: "compose", input: [:]))]
            case "content_block_delta":
                guard let block = open[index], event["delta"]?["type"] == "text_delta",
                    let text = event["delta"]?["text"]?.stringValue, !text.isEmpty
                else { return [] }
                open[index]?.characters += text.count
                return [.output(.init(id: block.id, text: text))]
            case "content_block_stop":
                guard let block = open.removeValue(forKey: index) else { return [] }
                let output: JSONValue = ["characters": .int(Int64(block.characters))]
                return [RunEvent(.toolResult(id: block.id, output: output, isError: false))]
            default:
                return []
            }
        }
    }

    /// `stream-json` parsing of one line.
    public static func parse(streamJSONLine line: String) -> StreamJSONLine {
        guard let value = try? CanonicalJSON.decode(JSONValue.self, from: Data(line.utf8)),
            let type = value["type"]?.stringValue
        else { return .other }
        switch type {
        case "stream_event":
            guard let event = value["event"] else { return .other }
            return .partial(event)
        case "assistant", "user":
            let blocks = value["message"]?["content"]?.arrayValue ?? []
            let role = value["message"]?["role"]?.stringValue ?? type
            return .events(blocks.compactMap { event(fromBlock: $0, role: role) })
        case "result":
            let usage = value["usage"]
            func tokens(_ key: String) -> Int64 { Int64(usage?[key]?.intValue ?? 0) }
            let input =
                tokens("input_tokens") + tokens("cache_read_input_tokens")
                + tokens("cache_creation_input_tokens")
            let dollars = value["total_cost_usd"]?.doubleValue ?? 0
            let cost = CostResult(
                inputTokens: input, outputTokens: tokens("output_tokens"),
                costMicros: Int64((dollars * 1_000_000).rounded()))
            let isError = value["is_error"]?.boolValue ?? (value["subtype"] != "success")
            return .final(
                text: value["result"]?.stringValue ?? "", isError: isError, cost: cost)
        default:
            return .other
        }
    }

    private static func event(fromBlock block: JSONValue, role: String) -> RunEvent? {
        switch block["type"]?.stringValue {
        case "text":
            guard let text = block["text"]?.stringValue else { return nil }
            return RunEvent(.message(role: role, text: text))
        case "thinking":
            guard let text = block["thinking"]?.stringValue else { return nil }
            return RunEvent(.thinking(text: text))
        case "tool_use":
            guard let id = block["id"]?.stringValue, let tool = block["name"]?.stringValue
            else { return nil }
            return RunEvent(.toolCall(id: id, tool: tool, input: block["input"] ?? .object([:])))
        case "tool_result":
            guard let id = block["tool_use_id"]?.stringValue else { return nil }
            return RunEvent(
                .toolResult(
                    id: id, output: block["content"] ?? .null,
                    isError: block["is_error"]?.boolValue ?? false))
        default:
            return nil
        }
    }
}

extension ExecOutput {
    /// What one `codex-json` output line means.
    public enum CodexJSONLine: Sendable, Hashable {
        /// A completed item, as run events; `reply` is set for an agent message.
        case events([RunEvent], reply: String?)
        /// A command or tool call that started and has not answered yet, as its `tool_call`.
        case started(RunEvent)
        /// A finished turn's token usage (Codex reports no dollar cost); turns add up.
        case usage(CostResult)
        /// A failed turn or a stream error.
        case failed(String)
        /// Anything else (thread and turn starts, other item starts, updates, non-JSON).
        case other

        /// The `tool_call` that opens these events, when they open with one.
        var startedCall: RunEvent? {
            guard case .events(let events, _) = self, let first = events.first,
                case .toolCall = first.body
            else { return nil }
            return first
        }
    }

    /// `codex-json` parsing of one line.
    public static func parse(codexJSONLine line: String) -> CodexJSONLine {
        guard let value = try? CanonicalJSON.decode(JSONValue.self, from: Data(line.utf8)),
            let type = value["type"]?.stringValue
        else { return .other }
        switch type {
        case "item.started":
            // A command or tool call shows as running before it answers.
            guard let item = value["item"], let call = codexItem(item).startedCall else {
                return .other
            }
            return .started(call)
        case "item.completed":
            guard let item = value["item"] else { return .other }
            return codexItem(item)
        case "turn.completed":
            let usage = value["usage"]
            return .usage(
                CostResult(
                    inputTokens: Int64(usage?["input_tokens"]?.intValue ?? 0),
                    outputTokens: Int64(usage?["output_tokens"]?.intValue ?? 0)))
        case "turn.failed", "error":
            let message =
                value["error"]?["message"]?.stringValue ?? value["message"]?.stringValue
                ?? "the agent reported an error"
            return .failed(message)
        default:
            return .other
        }
    }

    private static func codexItem(_ item: JSONValue) -> CodexJSONLine {
        let id = item["id"]?.stringValue ?? ""
        let failed = item["status"] == "failed"
        switch item["type"]?.stringValue {
        case "agent_message":
            guard let text = item["text"]?.stringValue else { return .other }
            return .events([RunEvent(.message(role: "assistant", text: text))], reply: text)
        case "reasoning":
            guard let text = item["text"]?.stringValue else { return .other }
            return .events([RunEvent(.thinking(text: text))], reply: nil)
        case "command_execution":
            let exitCode = item["exit_code"]?.intValue
            let input: JSONValue = ["command": item["command"] ?? .null]
            return .events(
                [
                    RunEvent(.toolCall(id: id, tool: "shell", input: input)),
                    RunEvent(
                        .toolResult(
                            id: id, output: item["aggregated_output"] ?? .null,
                            isError: failed || (exitCode ?? 0) != 0)),
                ], reply: nil)
        case "mcp_tool_call":
            let server = item["server"]?.stringValue ?? ""
            let tool = item["tool"]?.stringValue ?? ""
            let name = server.isEmpty ? tool : "\(server)/\(tool)"
            return .events(
                [
                    RunEvent(
                        .toolCall(id: id, tool: name, input: item["arguments"] ?? .object([:]))),
                    RunEvent(
                        .toolResult(
                            id: id, output: item["result"] ?? item["error"] ?? .null,
                            isError: failed)),
                ], reply: nil)
        default:
            return .other
        }
    }
}

/// A small JSON Schema checker for `run/start.resultSchema`: `type` (including lists of
/// types), `properties`, `required`, `additionalProperties: false`, `items`, `enum`, `const`,
/// `minItems`, and `maxItems`. Other keywords are ignored, so a schema using them is checked
/// only as far as these go.
public enum ResultSchema {
    /// The first place `value` breaks `schema`, as `<path>: <problem>`, or `nil` when it fits.
    public static func violation(of schema: JSONValue, by value: JSONValue, at path: String = "$")
        -> String?
    {
        guard case .object(let rules) = schema else { return nil }
        if let problem = typeViolation(rules["type"], value, path) { return problem }
        if let allowed = rules["enum"]?.arrayValue, !allowed.contains(value) {
            return "\(path): not one of the allowed values"
        }
        if let constant = rules["const"], constant != value {
            return "\(path): does not equal the constant"
        }
        switch value {
        case .object(let members): return objectViolation(rules, members, path)
        case .array(let items): return arrayViolation(rules, items, path)
        default: return nil
        }
    }

    private static func typeViolation(_ type: JSONValue?, _ value: JSONValue, _ path: String)
        -> String?
    {
        let names: [String]
        switch type {
        case .string(let name)?: names = [name]
        case .array(let list)?: names = list.compactMap(\.stringValue)
        default: return nil
        }
        if names.contains(where: { matches(value, type: $0) }) { return nil }
        return "\(path): expected \(names.joined(separator: " or "))"
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array),
            ("object", .object), ("integer", .int), ("number", .int), ("number", .double):
            return true
        case ("integer", .double(let number)):
            return number.rounded() == number
        default:
            return false
        }
    }

    private static func objectViolation(
        _ rules: [String: JSONValue], _ members: [String: JSONValue], _ path: String
    ) -> String? {
        for name in rules["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        where members[name] == nil {
            return "\(path): missing required \(name)"
        }
        let properties = rules["properties"]?.objectValue ?? [:]
        for name in members.keys.sorted() {
            guard let member = members[name] else { continue }
            if let schema = properties[name] {
                if let problem = violation(of: schema, by: member, at: "\(path).\(name)") {
                    return problem
                }
            } else if rules["additionalProperties"] == .bool(false) {
                return "\(path): unexpected property \(name)"
            }
        }
        return nil
    }

    private static func arrayViolation(
        _ rules: [String: JSONValue], _ items: [JSONValue], _ path: String
    ) -> String? {
        if let min = rules["minItems"]?.intValue, items.count < min {
            return "\(path): fewer than \(min) items"
        }
        if let max = rules["maxItems"]?.intValue, items.count > max {
            return "\(path): more than \(max) items"
        }
        guard let schema = rules["items"] else { return nil }
        for (index, item) in items.enumerated() {
            if let problem = violation(of: schema, by: item, at: "\(path)[\(index)]") {
                return problem
            }
        }
        return nil
    }
}
