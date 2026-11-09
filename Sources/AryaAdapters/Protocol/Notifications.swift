import AryaCore
import Foundation

/// One informational event streamed by an adapter during a run.
///
/// Unknown kinds decode as `.other` with every field kept, so newer adapters do not break
/// older hosts.
public struct RunEvent: Sendable, Hashable {
    /// When the adapter says the event happened. Informational; arya stamps its own time.
    public var at: String?
    public var body: Body

    public init(at: String? = nil, _ body: Body) {
        self.at = at
        self.body = body
    }

    public enum Body: Sendable, Hashable {
        case message(role: String, text: String)
        case thinking(text: String)
        case toolCall(id: String, tool: String, input: JSONValue)
        case toolResult(id: String, output: JSONValue, isError: Bool)
        case status(state: String, detail: String?)
        case error(message: String)
        /// A kind this version does not know, with all its fields except `kind` and `at`.
        case other(kind: String, fields: [String: JSONValue])
    }

    /// The `kind` string written on the wire.
    public var kind: String {
        switch body {
        case .message: "message"
        case .thinking: "thinking"
        case .toolCall: "tool_call"
        case .toolResult: "tool_result"
        case .status: "status"
        case .error: "error"
        case .other(let kind, _): kind
        }
    }
}

extension RunEvent: Codable {
    enum CodingKeys: String, CodingKey {
        case kind, at, role, text, id, tool, input, output, isError, state, detail, message
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(String.self, forKey: .at)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "message":
            body = .message(
                role: try c.decode(String.self, forKey: .role),
                text: try c.decode(String.self, forKey: .text))
        case "thinking":
            body = .thinking(text: try c.decode(String.self, forKey: .text))
        case "tool_call":
            body = .toolCall(
                id: try c.decode(String.self, forKey: .id),
                tool: try c.decode(String.self, forKey: .tool),
                input: try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null)
        case "tool_result":
            body = .toolResult(
                id: try c.decode(String.self, forKey: .id),
                output: try c.decodeIfPresent(JSONValue.self, forKey: .output) ?? .null,
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false)
        case "status":
            body = .status(
                state: try c.decode(String.self, forKey: .state),
                detail: try c.decodeIfPresent(String.self, forKey: .detail))
        case "error":
            body = .error(message: try c.decode(String.self, forKey: .message))
        default:
            var fields = try [String: JSONValue](from: decoder)
            fields["kind"] = nil
            fields["at"] = nil
            body = .other(kind: kind, fields: fields)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .other(let kind, let fields) = body {
            var all = fields
            all["kind"] = .string(kind)
            if let at { all["at"] = .string(at) }
            try all.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(at, forKey: .at)
        switch body {
        case .message(let role, let text):
            try c.encode(role, forKey: .role)
            try c.encode(text, forKey: .text)
        case .thinking(let text):
            try c.encode(text, forKey: .text)
        case .toolCall(let id, let tool, let input):
            try c.encode(id, forKey: .id)
            try c.encode(tool, forKey: .tool)
            try c.encode(input, forKey: .input)
        case .toolResult(let id, let output, let isError):
            try c.encode(id, forKey: .id)
            try c.encode(output, forKey: .output)
            try c.encode(isError, forKey: .isError)
        case .status(let state, let detail):
            try c.encode(state, forKey: .state)
            try c.encodeIfPresent(detail, forKey: .detail)
        case .error(let message):
            try c.encode(message, forKey: .message)
        case .other:
            break
        }
    }
}

/// Params of the `run/event` notification.
public struct RunEventParams: Sendable, Hashable, Codable {
    public var session: String
    /// Starts at 1 and increments by 1 per session.
    public var seq: Int
    public var event: RunEvent

    public init(session: String, seq: Int, event: RunEvent) {
        self.session = session
        self.seq = seq
        self.event = event
    }

    enum CodingKeys: String, CodingKey {
        case session, seq, event
    }
}

/// How a run ended.
public enum RunStatus: String, Sendable, Hashable, Codable {
    case completed, failed, stopped
}

/// Params of the `run/result` notification, sent exactly once per run.
public struct RunResultParams: Sendable, Hashable, Codable {
    public var session: String
    public var status: RunStatus
    /// The result. Kept raw so the runtime can validate it against `resultSchema` and record
    /// it even when it does not decode; use ``decodedResult()`` for the typed form.
    public var result: JSONValue?

    public init(session: String, status: RunStatus, result: JSONValue? = nil) {
        self.session = session
        self.status = status
        self.result = result
    }

    public init(session: String, status: RunStatus, result: RunResult) throws {
        self.init(session: session, status: status, result: try JSONValue(encoding: result))
    }

    /// The typed result; an absent result decodes as an empty one.
    public func decodedResult() throws -> RunResult {
        guard let result, result != .null else { return RunResult() }
        return try result.decode(RunResult.self)
    }

    enum CodingKeys: String, CodingKey {
        case session, status, result
    }
}

/// What a run produced. Every list may be empty or absent on the wire; absent lists decode as
/// empty. Unknown fields are ignored.
public struct RunResult: Sendable, Hashable, Codable {
    public var summary: String
    /// The run's plan as it stood at the end: what it set out to do and how far it got.
    public var plan: [PlanStep]
    public var decisions: [Decision]
    public var actions: [Action]
    public var delegations: [Delegation]
    public var memories: [Memory]
    public var routines: [Routine]
    public var measurements: [Measurement]

    public init(
        summary: String = "", plan: [PlanStep] = [], decisions: [Decision] = [],
        actions: [Action] = [], delegations: [Delegation] = [], memories: [Memory] = [],
        routines: [Routine] = [], measurements: [Measurement] = []
    ) {
        self.summary = summary
        self.plan = plan
        self.decisions = decisions
        self.actions = actions
        self.delegations = delegations
        self.memories = memories
        self.routines = routines
        self.measurements = measurements
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        plan = try c.decodeIfPresent([PlanStep].self, forKey: .plan) ?? []
        decisions = try c.decodeIfPresent([Decision].self, forKey: .decisions) ?? []
        actions = try c.decodeIfPresent([Action].self, forKey: .actions) ?? []
        delegations = try c.decodeIfPresent([Delegation].self, forKey: .delegations) ?? []
        memories = try c.decodeIfPresent([Memory].self, forKey: .memories) ?? []
        routines = try c.decodeIfPresent([Routine].self, forKey: .routines) ?? []
        measurements = try c.decodeIfPresent([Measurement].self, forKey: .measurements) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case summary, plan, decisions, actions, delegations, memories, routines, measurements
    }

    /// Absent lists are omitted, so a result without a plan encodes as it did before plans.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(summary, forKey: .summary)
        if !plan.isEmpty { try c.encode(plan, forKey: .plan) }
        try c.encode(decisions, forKey: .decisions)
        try c.encode(actions, forKey: .actions)
        try c.encode(delegations, forKey: .delegations)
        try c.encode(memories, forKey: .memories)
        try c.encode(routines, forKey: .routines)
        try c.encode(measurements, forKey: .measurements)
    }

    /// One step of the run's plan.
    public struct PlanStep: Sendable, Hashable, Codable {
        public var id: String
        public var text: String
        public var status: PlanStatus
        public var rationale: String?

        public init(id: String, text: String, status: PlanStatus, rationale: String? = nil) {
            self.id = id
            self.text = text
            self.status = status
            self.rationale = rationale
        }

        enum CodingKeys: String, CodingKey {
            case id, text, status, rationale
        }
    }

    /// How far a plan step got.
    public enum PlanStatus: String, Sendable, Hashable, Codable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case done
        case skipped
        case blocked
    }

    /// The adapter's hint of how much an action could go wrong. arya's policy decides; the hint
    /// only informs the person reviewing it.
    public enum Risk: String, Sendable, Hashable, Codable, CaseIterable {
        case low, medium, high
    }

    /// A choice the run made, with its reason.
    public struct Decision: Sendable, Hashable, Codable {
        public var id: String
        public var choice: String
        public var rationale: String?
        /// One line a person reads in the app: why this choice.
        public var why: String?

        public init(id: String, choice: String, rationale: String? = nil, why: String? = nil) {
            self.id = id
            self.choice = choice
            self.rationale = rationale
            self.why = why
        }

        enum CodingKeys: String, CodingKey {
            case id, choice, rationale, why
        }
    }

    /// An action the run proposes. arya, not the adapter, decides whether it executes.
    public struct Action: Sendable, Hashable, Codable {
        public var id: String
        public var kind: String
        public var binding: String?
        public var target: String?
        public var params: JSONValue?
        public var rationale: String?
        /// The adapter's risk hint; policy, not the hint, decides what runs.
        public var risk: Risk?
        /// One line a person reads in the app: why this action.
        public var why: String?

        public init(
            id: String, kind: String, binding: String? = nil, target: String? = nil,
            params: JSONValue? = nil, rationale: String? = nil, risk: Risk? = nil,
            why: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.binding = binding
            self.target = target
            self.params = params
            self.rationale = rationale
            self.risk = risk
            self.why = why
        }

        enum CodingKeys: String, CodingKey {
            case id, kind, binding, target, params, rationale, risk, why
        }
    }

    /// Work to hand to a child run after this run finishes.
    public struct Delegation: Sendable, Hashable, Codable {
        public var id: String
        public var title: String
        public var input: String
        /// The adapter profile to run the child with; absent means the parent's. arya runs it
        /// only when the charter's `crew.adapters` lists it.
        public var adapter: String?
        /// The child's effort; arya caps it at the parent's.
        public var effort: String?
        /// The child's budget; arya caps each limit at the parent's.
        public var limits: RunLimits?

        public init(
            id: String, title: String, input: String, adapter: String? = nil,
            effort: String? = nil, limits: RunLimits? = nil
        ) {
            self.id = id
            self.title = title
            self.input = input
            self.adapter = adapter
            self.effort = effort
            self.limits = limits
        }

        enum CodingKeys: String, CodingKey {
            case id, title, input, adapter, effort, limits
        }
    }

    /// A note the run wants to keep for future runs.
    public struct Memory: Sendable, Hashable, Codable {
        public var text: String
        public var tags: [String]

        public init(text: String, tags: [String] = []) {
            self.text = text
            self.tags = tags
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case text, tags
        }
    }

    /// A routine the run proposes to add or change.
    public struct Routine: Sendable, Hashable, Codable {
        public var name: String
        public var language: String
        public var content: String
        public var reason: String?

        public init(name: String, language: String, content: String, reason: String? = nil) {
            self.name = name
            self.language = language
            self.content = content
            self.reason = reason
        }

        enum CodingKeys: String, CodingKey {
            case name, language, content, reason
        }
    }

    /// A metric reading the run observed.
    public struct Measurement: Sendable, Hashable, Codable {
        public var metric: String
        public var value: Double

        public init(metric: String, value: Double) {
            self.metric = metric
            self.value = value
        }

        enum CodingKeys: String, CodingKey {
            case metric, value
        }
    }
}
