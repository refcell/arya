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

/// Whether a harness's built-in write tools are confined to the run's workdir.
public enum SandboxSupport: String, Sendable, Hashable, Codable {
    case workdir
    case none
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

    public init(
        run: String, instructions: String, input: RunInput, effort: String = "medium",
        workdir: String, tools: [ToolServer] = [], limits: RunLimits = RunLimits(),
        resultSchema: JSONValue? = nil
    ) {
        self.run = run
        self.instructions = instructions
        self.input = input
        self.effort = effort
        self.workdir = workdir
        self.tools = tools
        self.limits = limits
        self.resultSchema = resultSchema
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
    }

    enum CodingKeys: String, CodingKey {
        case run, instructions, input, effort, workdir, tools, limits, resultSchema
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
