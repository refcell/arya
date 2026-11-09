import AryaAdapters
import AryaCore

/// Carries out approved actions through their bindings (M4).
///
/// An MCP binding's action calls the tool named by the action kind on the binding's server,
/// with the action's `params` (an object) plus `target` as arguments; each action starts a
/// fresh server and closes it after. A person binding's action is delivered to the local inbox:
/// the `action.executed` output `{inbox, channel, target?, params?}` is the inbox entry. A
/// `routine` action goes to `routines` when set. Kinds the binding does not allow fail.
public struct BindingActionExecutor: ActionExecutor {
    private let connect: @Sendable (CharterBinding) async throws -> any ToolUpstream
    private let routines: (any ActionExecutor)?

    /// Creates an executor. `connect` opens a binding's server (by default its `command` and
    /// `args` as a child process).
    public init(
        routines: (any ActionExecutor)? = nil,
        connect: @escaping @Sendable (CharterBinding) async throws -> any ToolUpstream =
            BindingActionExecutor.spawn
    ) {
        self.routines = routines
        self.connect = connect
    }

    /// Starts a binding's MCP server as a child process.
    @Sendable public static func spawn(_ binding: CharterBinding) async throws
        -> any ToolUpstream
    {
        guard let command = binding.command else {
            throw RPCError(code: RPCErrorCode.invalidParams, message: "binding has no command")
        }
        return try ProcessToolUpstream(command: command, args: binding.args)
    }

    public func execute(_ request: ExecutionRequest) async -> ExecutionOutcome {
        let action = request.action
        if action.kind == ActionPolicy.routineKind {
            guard let routines else {
                return .failed(error: "no routine runner", output: nil)
            }
            return await routines.execute(request)
        }
        guard let binding = request.binding else {
            return .failed(error: "no_binding", output: nil)
        }
        guard binding.actions.contains(action.kind) else {
            return .failed(error: "not_allowed:\(binding.id).\(action.kind)", output: nil)
        }
        switch binding.kind {
        case .person: return .succeeded(output: Self.inboxEntry(binding, action))
        case .mcp: return await call(binding, action)
        }
    }

    private func call(_ binding: CharterBinding, _ action: ProposedAction) async
        -> ExecutionOutcome
    {
        let upstream: any ToolUpstream
        do {
            upstream = try await connect(binding)
        } catch {
            return .failed(error: "connect: \(error)", output: nil)
        }
        defer { Task { await upstream.close() } }
        do {
            let result = try await upstream.call(action.kind, arguments: Self.arguments(action))
            let output = result["structuredContent"] ?? result["content"] ?? .null
            if result["isError"]?.boolValue == true {
                return .failed(error: Self.text(result) ?? "tool error", output: output)
            }
            return .succeeded(output: output)
        } catch {
            return .failed(error: "\(error)", output: nil)
        }
    }

    /// `params` (when an object) plus `target`, unless `params` already names one.
    static func arguments(_ action: ProposedAction) -> JSONValue {
        var members: [String: JSONValue] = [:]
        if case .object(let params)? = action.params { members = params }
        if let target = action.target, members["target"] == nil {
            members["target"] = .string(target)
        }
        return .object(members)
    }

    static func inboxEntry(_ binding: CharterBinding, _ action: ProposedAction) -> JSONValue {
        var entry: [String: JSONValue] = [
            "inbox": .string(binding.id), "channel": binding.channel.map { .string($0) } ?? .null,
        ]
        if let target = action.target { entry["target"] = .string(target) }
        if let params = action.params { entry["params"] = params }
        return .object(entry)
    }

    /// The first text content of a tool result.
    private static func text(_ result: JSONValue) -> String? {
        result["content"]?.arrayValue?.lazy.compactMap { $0["text"]?.stringValue }.first
    }
}
