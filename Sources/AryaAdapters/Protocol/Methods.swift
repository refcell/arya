import AryaCore
import Foundation

/// The adapter protocol version this module speaks.
public let adapterProtocolVersion = 1

/// The name and version of one side of a connection.
public struct PeerInfo: Sendable, Hashable, Codable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }

    enum CodingKeys: String, CodingKey {
        case name, version
    }
}

/// Params of `initialize`.
public struct InitializeParams: Sendable, Hashable, Codable {
    public var protocolVersion: Int
    public var client: PeerInfo

    public init(protocolVersion: Int = adapterProtocolVersion, client: PeerInfo) {
        self.protocolVersion = protocolVersion
        self.client = client
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case client
    }
}

/// How an adapter hands tools to its harness.
public enum ToolSupport: String, Sendable, Hashable, Codable {
    case mcp
    case none
}

/// How a harness's writes are confined.
public enum SandboxSupport: String, Sendable, Hashable, Codable {
    /// The adapter launches the harness under the OS sandbox profile `run/start.sandbox`
    /// carries (macOS `sandbox-exec`).
    case os
    /// The harness's built-in write tools are confined to the run's workdir or off.
    case workdir
    case none
}

/// An OS sandbox for the harness, chosen by arya and sent in `run/start.sandbox`: a macOS
/// sandbox profile (SBPL text) and the parameters it reads with `(param "NAME")`. Only an
/// adapter reporting capability `sandbox: "os"` accepts it.
public struct SandboxRequest: Sendable, Hashable, Codable {
    public var profile: String
    public var params: [String: String]

    public init(profile: String, params: [String: String] = [:]) {
        self.profile = profile
        self.params = params
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decode(String.self, forKey: .profile)
        params = try c.decodeIfPresent([String: String].self, forKey: .params) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case profile, params
    }
}

/// What an adapter can do, reported by `initialize`.
public struct Capabilities: Sendable, Hashable, Codable {
    /// Effort levels the adapter maps to a model (`low`, `medium`, `high`).
    public var effort: [String]
    public var send: Bool
    public var cost: Bool
    public var transcript: Bool
    public var tools: ToolSupport
    public var sandbox: SandboxSupport

    public init(
        effort: [String] = ["low", "medium", "high"], send: Bool = false, cost: Bool = false,
        transcript: Bool = false, tools: ToolSupport = .none, sandbox: SandboxSupport = .none
    ) {
        self.effort = effort
        self.send = send
        self.cost = cost
        self.transcript = transcript
        self.tools = tools
        self.sandbox = sandbox
    }

    enum CodingKeys: String, CodingKey {
        case effort, send, cost, transcript, tools, sandbox
    }
}

/// Result of `initialize`.
public struct InitializeResult: Sendable, Hashable, Codable {
    public var protocolVersion: Int
    public var adapter: PeerInfo
    public var capabilities: Capabilities

    public init(
        protocolVersion: Int = adapterProtocolVersion, adapter: PeerInfo,
        capabilities: Capabilities
    ) {
        self.protocolVersion = protocolVersion
        self.adapter = adapter
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case adapter, capabilities
    }
}

/// What started a run.
public enum RunInputKind: String, Sendable, Hashable, Codable {
    case manual, schedule, message, `case`, join
}

/// The input a run works on.
public struct RunInput: Sendable, Hashable, Codable {
    public var kind: RunInputKind
    public var text: String
    public var attachments: [JSONValue]

    public init(kind: RunInputKind, text: String, attachments: [JSONValue] = []) {
        self.kind = kind
        self.text = text
        self.attachments = attachments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(RunInputKind.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([JSONValue].self, forKey: .attachments) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case kind, text, attachments
    }
}

/// An MCP server handed to the harness (an arya binding proxy).
public struct ToolServer: Sendable, Hashable, Codable {
    public var name: String
    public var transport: String
    public var command: String
    public var args: [String]

    public init(name: String, transport: String = "stdio", command: String, args: [String] = []) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
    }

    enum CodingKeys: String, CodingKey {
        case name, transport, command, args
    }
}

/// Limits for one run. Every field is optional on the wire.
public struct RunLimits: Sendable, Hashable, Codable {
    public var maxTurns: Int?
    public var timeoutSeconds: Int?
    public var maxCostMicros: Int64?

    public init(maxTurns: Int? = nil, timeoutSeconds: Int? = nil, maxCostMicros: Int64? = nil) {
        self.maxTurns = maxTurns
        self.timeoutSeconds = timeoutSeconds
        self.maxCostMicros = maxCostMicros
    }

    enum CodingKeys: String, CodingKey {
        case maxTurns, timeoutSeconds, maxCostMicros
    }
}

/// Params of `run/start`.
public struct RunStartParams: Sendable, Hashable, Codable {
    public var run: String
    public var instructions: String
    public var input: RunInput
    /// `low`, `medium`, or `high`.
    public var effort: String
    public var workdir: String
    public var tools: [ToolServer]
    public var limits: RunLimits
    public var resultSchema: JSONValue?
    /// An OS sandbox to run the harness in; absent means none.
    public var sandbox: SandboxRequest?

    public init(
        run: String, instructions: String, input: RunInput, effort: String = "medium",
        workdir: String, tools: [ToolServer] = [], limits: RunLimits = RunLimits(),
        resultSchema: JSONValue? = nil, sandbox: SandboxRequest? = nil
    ) {
        self.run = run
        self.instructions = instructions
        self.input = input
        self.effort = effort
        self.workdir = workdir
        self.tools = tools
        self.limits = limits
        self.resultSchema = resultSchema
        self.sandbox = sandbox
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        run = try container.decode(String.self, forKey: .run)
        instructions = try container.decode(String.self, forKey: .instructions)
        input = try container.decode(RunInput.self, forKey: .input)
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? "medium"
        workdir = try container.decode(String.self, forKey: .workdir)
        tools = try container.decodeIfPresent([ToolServer].self, forKey: .tools) ?? []
        limits = try container.decodeIfPresent(RunLimits.self, forKey: .limits) ?? RunLimits()
        resultSchema = try container.decodeIfPresent(JSONValue.self, forKey: .resultSchema)
        sandbox = try container.decodeIfPresent(SandboxRequest.self, forKey: .sandbox)
    }

    enum CodingKeys: String, CodingKey {
        case run, instructions, input, effort, workdir, tools, limits, resultSchema, sandbox
    }
}

/// Result of `run/start`.
public struct RunStartResult: Sendable, Hashable, Codable {
    public var session: String

    public init(session: String) { self.session = session }

    enum CodingKeys: String, CodingKey {
        case session
    }
}

/// A person's message delivered mid-run.
public struct HumanMessage: Sendable, Hashable, Codable {
    public var role: String
    public var author: String?
    public var text: String

    public init(role: String = "human", author: String? = nil, text: String) {
        self.role = role
        self.author = author
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case role, author, text
    }
}

/// Params of `run/send`.
public struct RunSendParams: Sendable, Hashable, Codable {
    public var session: String
    public var message: HumanMessage

    public init(session: String, message: HumanMessage) {
        self.session = session
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case session, message
    }
}

/// Why a run is being stopped.
public enum StopReason: String, Sendable, Hashable, Codable {
    case user, timeout, budget
}

/// Params of `run/stop`.
public struct RunStopParams: Sendable, Hashable, Codable {
    public var session: String
    public var reason: StopReason

    public init(session: String, reason: StopReason) {
        self.session = session
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case session, reason
    }
}

/// Params of methods that name only a session (`run/transcript`, `run/cost`).
public struct SessionParams: Sendable, Hashable, Codable {
    public var session: String

    public init(session: String) { self.session = session }

    enum CodingKeys: String, CodingKey {
        case session
    }
}

/// Result of `run/transcript`.
public struct TranscriptResult: Sendable, Hashable, Codable {
    public var events: [RunEvent]

    public init(events: [RunEvent]) { self.events = events }

    enum CodingKeys: String, CodingKey {
        case events
    }
}

/// Result of `run/cost`, in tokens and micro-dollars.
public struct CostResult: Sendable, Hashable, Codable {
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var costMicros: Int64

    public init(inputTokens: Int64 = 0, outputTokens: Int64 = 0, costMicros: Int64 = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costMicros = costMicros
    }

    /// Absent totals decode as zero.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        costMicros = try c.decodeIfPresent(Int64.self, forKey: .costMicros) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, costMicros
    }
}

/// The empty object `{}`, the result of `run/send`, `run/stop`, and `shutdown`.
public struct EmptyObject: Sendable, Hashable, Codable {
    public init() {}
}

/// Params of the `host/ask` request (adapter to arya).
public struct HostAskParams: Sendable, Hashable, Codable {
    public var session: String
    public var question: String
    public var to: String?

    public init(session: String, question: String, to: String? = nil) {
        self.session = session
        self.question = question
        self.to = to
    }

    enum CodingKeys: String, CodingKey {
        case session, question, to
    }
}

/// Result of `host/ask`. A `nil` answer is written as `"answer": null`.
public struct HostAskResult: Sendable, Hashable, Codable {
    public var answer: String?

    public init(answer: String?) { self.answer = answer }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(answer, forKey: .answer)
    }

    enum CodingKeys: String, CodingKey {
        case answer
    }
}

/// Params of the `host/delegate` request (adapter to arya): run a child of this run on `input`
/// and answer with its outcome. `id` names the delegation within the run. Like
/// `run/result.delegations`, the child keeps the parent's charter and input kind and may name an
/// `adapter`, `effort`, and `limits`.
public struct HostDelegateParams: Sendable, Hashable, Codable {
    public var session: String
    public var id: String
    public var title: String
    public var input: String
    /// As on a `run/result` delegation: the adapter profile (one `crew.adapters` lists),
    /// effort, and budget; arya caps each at the parent run's.
    public var adapter: String?
    public var effort: String?
    public var limits: RunLimits?

    public init(
        session: String, id: String, title: String, input: String, adapter: String? = nil,
        effort: String? = nil, limits: RunLimits? = nil
    ) {
        self.session = session
        self.id = id
        self.title = title
        self.input = input
        self.adapter = adapter
        self.effort = effort
        self.limits = limits
    }

    /// The same request as a `run/result` delegation, so the host runs both alike.
    public var delegation: RunResult.Delegation {
        RunResult.Delegation(
            id: id, title: title, input: input, adapter: adapter, effort: effort, limits: limits)
    }

    enum CodingKeys: String, CodingKey {
        case session, id, title, input, adapter, effort, limits
    }
}

/// How a delegated child run ended, or `refused` when arya did not start one.
public enum DelegationStatus: String, Sendable, Hashable, Codable {
    case completed, stopped, failed, refused
}

/// Result of `host/delegate`, sent when the child run ends. `result` is the child's
/// `run/result.result` (for `completed`); `reason` explains `failed` and `refused`.
public struct HostDelegateResult: Sendable, Hashable, Codable {
    /// The child's run id; absent when refused.
    public var run: String?
    public var status: DelegationStatus
    public var result: JSONValue?
    public var reason: String?

    public init(
        run: String? = nil, status: DelegationStatus, result: JSONValue? = nil,
        reason: String? = nil
    ) {
        self.run = run
        self.status = status
        self.result = result
        self.reason = reason
    }

    /// A refusal: arya did not start a child (depth limit, rehearsal, or no support).
    public static func refused(_ reason: String) -> HostDelegateResult {
        HostDelegateResult(status: .refused, reason: reason)
    }

    enum CodingKeys: String, CodingKey {
        case run, status, result, reason
    }
}
