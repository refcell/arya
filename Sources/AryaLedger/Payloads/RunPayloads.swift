import AryaCore

/// What started a run; the same values as `run/start.input.kind`.
public enum RunTriggerKind: String, Hashable, Sendable, Codable {
    case manual, schedule, message, `case`, join, replan, report
}

/// The input a run received, in the shape of `run/start.input`.
public struct RunInputRecord: Hashable, Sendable, Codable {
    public var kind: RunTriggerKind
    public var text: String
    public var attachments: [JSONValue]?

    public init(kind: RunTriggerKind, text: String, attachments: [JSONValue]? = nil) {
        self.kind = kind
        self.text = text
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey { case kind, text, attachments }
}

/// `run.started`: everything the run will see, so it can be replayed exactly.
public struct RunStarted: EventPayload {
    public static let type = EventType.runStarted
    public var input: RunInputRecord
    public var charterVersion: Int
    /// Live routine versions by name (content hashes).
    public var routines: [String: String]
    /// The memory snapshot (`AryaMemory.MemorySnapshot`), opaque here.
    public var memory: JSONValue?
    /// Adapter profile name.
    public var adapter: String
    public var effort: Effort
    /// The composed instructions sent in `run/start`.
    public var instructions: String
    public var limits: Limits
    /// The parent of a crew child or join run.
    public var parent: RunID?
    /// Set when the run rehearses a case.
    public var rehearsal: RehearsalID?
    public var caseID: CaseID?
    /// 1-based sample number within a rehearsal.
    public var sample: Int?
    /// How the run's routines and binding servers were confined, for example
    /// `{kind: sandbox-exec, workdir, network: [binding ids]}`; nil when they were not.
    public var sandbox: JSONValue?

    public init(
        input: RunInputRecord, charterVersion: Int, routines: [String: String] = [:],
        memory: JSONValue? = nil, adapter: String, effort: Effort, instructions: String,
        limits: Limits, parent: RunID? = nil, rehearsal: RehearsalID? = nil,
        caseID: CaseID? = nil, sample: Int? = nil, sandbox: JSONValue? = nil
    ) {
        self.sandbox = sandbox
        self.input = input
        self.charterVersion = charterVersion
        self.routines = routines
        self.memory = memory
        self.adapter = adapter
        self.effort = effort
        self.instructions = instructions
        self.limits = limits
        self.parent = parent
        self.rehearsal = rehearsal
        self.caseID = caseID
        self.sample = sample
    }

    enum CodingKeys: String, CodingKey {
        case input, charterVersion, routines, memory, adapter, effort, instructions, limits
        case parent, rehearsal, sample, sandbox
        case caseID = "case"
    }
}

/// `run.input`: a person's message delivered mid-run (`run/send`), or the answer to a
/// `host/ask` question. The person is the envelope's actor.
public struct RunInputReceived: EventPayload {
    public static let type = EventType.runInput

    public enum Kind: String, Hashable, Sendable, Codable { case message, answer }

    public var kind: Kind
    /// Nil when a question went unanswered.
    public var text: String?
    /// The approval that carried the question, for answers.
    public var approval: ApprovalID?

    public init(kind: Kind, text: String?, approval: ApprovalID? = nil) {
        self.kind = kind
        self.text = text
        self.approval = approval
    }

    enum CodingKeys: String, CodingKey { case kind, text, approval }
}

/// `run.adapter.event`: one adapter protocol line, in either direction, in the order read or
/// written. `message` is the parsed JSON; a line that is not JSON keeps its text in `raw`.
public struct RunAdapterEvent: EventPayload {
    public static let type = EventType.runAdapterEvent

    public enum Direction: String, Hashable, Sendable, Codable {
        /// arya to adapter.
        case sent
        /// Adapter to arya.
        case received
    }

    public var direction: Direction
    public var message: JSONValue?
    public var raw: String?

    public init(direction: Direction, message: JSONValue) {
        self.direction = direction
        self.message = message
    }

    public init(direction: Direction, raw: String) {
        self.direction = direction
        self.raw = raw
    }

    enum CodingKeys: String, CodingKey { case direction, message, raw }
}

/// `run.tool.call`: a harness called a read tool through the binding proxy.
public struct RunToolCall: EventPayload {
    public static let type = EventType.runToolCall
    /// Unique within the run.
    public var id: String
    public var binding: String
    public var tool: String
    public var input: JSONValue

    public init(id: String, binding: String, tool: String, input: JSONValue) {
        self.id = id
        self.binding = binding
        self.tool = tool
        self.input = input
    }

    enum CodingKeys: String, CodingKey { case id, binding, tool, input }
}

/// `run.tool.result`: the answer to a tool call.
public struct RunToolResult: EventPayload {
    public static let type = EventType.runToolResult

    public enum Source: String, Hashable, Sendable, Codable {
        /// The live system answered.
        case live
        /// A recording answered (rehearsal or replay).
        case recorded
        /// Nothing in the case's context matched; the rehearsal case is a `leak`.
        case unanswered
    }

    public var id: String
    public var output: JSONValue
    public var isError: Bool
    public var source: Source

    public init(id: String, output: JSONValue, isError: Bool = false, source: Source = .live) {
        self.id = id
        self.output = output
        self.isError = isError
        self.source = source
    }

    enum CodingKeys: String, CodingKey { case id, output, isError, source }
}

/// One decision from `run/result`.
public struct RecordedDecision: Hashable, Sendable, Codable {
    public var id: String
    public var choice: String
    public var rationale: String?
    /// One line a person reads: why this choice.
    public var why: String?

    public init(id: String, choice: String, rationale: String? = nil, why: String? = nil) {
        self.id = id
        self.choice = choice
        self.rationale = rationale
        self.why = why
    }

    enum CodingKeys: String, CodingKey { case id, choice, rationale, why }
}

/// `run.decision`.
public struct RunDecision: EventPayload {
    public static let type = EventType.runDecision
    public var decision: RecordedDecision

    public init(decision: RecordedDecision) { self.decision = decision }

    enum CodingKeys: String, CodingKey { case decision }
}

/// Token and money cost of a run, from `run/cost`.
public struct RunCost: Hashable, Sendable, Codable {
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var costMicros: Int64

    public init(inputTokens: Int64 = 0, outputTokens: Int64 = 0, costMicros: Int64 = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costMicros = costMicros
    }

    enum CodingKeys: String, CodingKey { case inputTokens, outputTokens, costMicros }
}

/// Counts of what a run's result contained.
public struct RunCounts: Hashable, Sendable, Codable {
    public var decisions: Int
    public var actions: Int
    public var delegations: Int
    public var memories: Int
    public var routines: Int
    public var measurements: Int

    public init(
        decisions: Int = 0, actions: Int = 0, delegations: Int = 0, memories: Int = 0,
        routines: Int = 0, measurements: Int = 0
    ) {
        self.decisions = decisions
        self.actions = actions
        self.delegations = delegations
        self.memories = memories
        self.routines = routines
        self.measurements = measurements
    }

    enum CodingKeys: String, CodingKey {
        case decisions, actions, delegations, memories, routines, measurements
    }
}

/// `run.finished`: the adapter returned `run/result` and its actions were disposed of.
public struct RunFinished: EventPayload {
    public static let type = EventType.runFinished

    /// The runtime's `RunEndStatus` values.
    public enum Status: String, Hashable, Sendable, Codable { case completed, stopped }

    public var status: Status
    public var summary: String?
    public var cost: RunCost
    public var counts: RunCounts

    public init(
        status: Status, summary: String? = nil, cost: RunCost = RunCost(),
        counts: RunCounts = RunCounts()
    ) {
        self.status = status
        self.summary = summary
        self.cost = cost
        self.counts = counts
    }

    enum CodingKeys: String, CodingKey { case status, summary, cost, counts }
}

/// `run.abort.requested`: a person asked arya to stop a running run (actor: that person). The
/// process running it sends `run/stop` (`user`), executes nothing the run proposes, and ends it
/// `run.finished` with status `stopped`, or `run.failed` with reason `aborted` when the adapter
/// exits without a result or no process holds the run.
public struct RunAbortRequested: EventPayload {
    public static let type = EventType.runAbortRequested
    /// Why, in the person's words.
    public var reason: String?

    public init(reason: String? = nil) { self.reason = reason }

    enum CodingKeys: String, CodingKey { case reason }
}

/// `run.failed`: the run ended without a usable result.
public struct RunFailed: EventPayload {
    public static let type = EventType.runFailed
    /// A runtime `RunFailureReason` raw value (`adapter_exited`, `timeout`, `invalid_result`,
    /// `budget`, `interrupted`, `adapter_failed`); a string so new reasons stay readable.
    public var reason: String
    public var detail: String?
    public var cost: RunCost?

    public init(reason: String, detail: String? = nil, cost: RunCost? = nil) {
        self.reason = reason
        self.detail = detail
        self.cost = cost
    }

    enum CodingKeys: String, CodingKey { case reason, detail, cost }
}
