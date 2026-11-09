/// A connection to a system (an MCP server) or a person (a contact channel). Named
/// `CharterBinding` so it never collides with SwiftUI's `Binding` (decision 0011).
public struct CharterBinding: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case mcp, person }

    /// Unique within the charter, for example `tracker` or `person:alex`.
    public var id: String
    public var kind: Kind
    /// `mcp`: the server command and its arguments.
    public var command: String?
    public var args: [String]
    /// `mcp`: tools a harness may call during a run.
    public var read: [String]
    /// `mcp`: action kinds arya may execute through this binding.
    public var actions: [String]
    /// `person`: how to reach them, for example `inbox`.
    public var channel: String?
    /// `mcp`: the server may use the network when arya sandboxes it (decision 0040).
    public var network: Bool = false

    /// An MCP server binding.
    public static func mcp(
        _ id: String, command: String, args: [String] = [], read: [String] = [],
        actions: [String] = []
    ) -> CharterBinding {
        CharterBinding(
            id: id, kind: .mcp, command: command, args: args, read: read, actions: actions,
            channel: nil)
    }

    /// A person binding.
    public static func person(_ id: String, channel: String) -> CharterBinding {
        CharterBinding(
            id: id, kind: .person, command: nil, args: [], read: [], actions: [], channel: channel)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, command, args, read, actions, channel, network
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        read = try c.decodeIfPresent([String].self, forKey: .read) ?? []
        actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        network = try c.decodeIfPresent(Bool.self, forKey: .network) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(command, forKey: .command)
        if kind == .mcp {
            try c.encode(args, forKey: .args)
            try c.encode(read, forKey: .read)
            try c.encode(actions, forKey: .actions)
        }
        try c.encodeIfPresent(channel, forKey: .channel)
        if network { try c.encode(network, forKey: .network) }
    }

    init(
        id: String, kind: Kind, command: String?, args: [String], read: [String],
        actions: [String], channel: String?
    ) {
        self.id = id
        self.kind = kind
        self.command = command
        self.args = args
        self.read = read
        self.actions = actions
        self.channel = channel
    }
}

/// What starts a run of a live steward. Encoded as `{"kind":"interval","everySeconds":900}`,
/// `{"kind":"manual"}`, or `{"kind":"message","from":"person:alex"}` (`from` optional; it
/// names a person binding).
public enum Trigger: Hashable, Sendable, Codable {
    case interval(everySeconds: Int)
    case manual
    case message(from: String?)

    private enum CodingKeys: String, CodingKey { case kind, everySeconds, from }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "interval":
            self = .interval(everySeconds: try c.decode(Int.self, forKey: .everySeconds))
        case "manual": self = .manual
        case "message": self = .message(from: try c.decodeIfPresent(String.self, forKey: .from))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown trigger kind \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let seconds):
            try c.encode("interval", forKey: .kind)
            try c.encode(seconds, forKey: .everySeconds)
        case .manual:
            try c.encode("manual", forKey: .kind)
        case .message(let from):
            try c.encode("message", forKey: .kind)
            try c.encodeIfPresent(from, forKey: .from)
        }
    }
}

/// How a proposed action is disposed of.
public enum PolicyDecision: String, Hashable, Sendable, Codable {
    /// Execute without asking.
    case auto
    /// Hold for a person's approval.
    case ask
    /// Record as rejected; never execute.
    case deny
}

/// The approval policy: rules by action kind (optionally per binding), then a default that is
/// `ask` when omitted (decision 0018).
public struct Policy: Hashable, Sendable, Codable {
    public struct Rule: Hashable, Sendable, Codable {
        public var action: String
        /// Limits the rule to one binding; nil matches any binding.
        public var binding: String?
        public var decision: PolicyDecision
        /// The guardrail in a person's words, shown where the rule holds an action, for
        /// example "Replies to customers need sign-off".
        public var note: String?

        public init(
            action: String, binding: String? = nil, decision: PolicyDecision, note: String? = nil
        ) {
            self.action = action
            self.binding = binding
            self.decision = decision
            self.note = note
        }

        private enum CodingKeys: String, CodingKey { case action, binding, decision, note }
    }

    public var `default`: PolicyDecision
    public var rules: [Rule]
    /// Risk levels by action kind, routine, or binding (decision 0037); omitted when empty.
    public var risk: [RiskRule]

    public init(default: PolicyDecision = .ask, rules: [Rule] = [], risk: [RiskRule] = []) {
        self.default = `default`
        self.rules = rules
        self.risk = risk
    }

    /// The decision for an action of `kind` through `binding`. A binding-specific rule beats
    /// a general one; among equals the first listed wins; otherwise the default applies.
    public func decision(forAction kind: String, binding: String? = nil) -> PolicyDecision {
        let matching = rules.filter { $0.action == kind }
        if let binding, let specific = matching.first(where: { $0.binding == binding }) {
            return specific.decision
        }
        return matching.first(where: { $0.binding == nil })?.decision ?? self.default
    }

    private enum CodingKeys: String, CodingKey { case `default`, rules, risk }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.default = try c.decodeIfPresent(PolicyDecision.self, forKey: .default) ?? .ask
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        risk = try c.decodeIfPresent([RiskRule].self, forKey: .risk) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.default, forKey: .default)
        try c.encode(rules, forKey: .rules)
        if !risk.isEmpty { try c.encode(risk, forKey: .risk) }
    }
}

/// How rehearsal scores a case. Named `ScorerSpec` because `AryaEval` owns the `Scorer`
/// protocol that implements it.
public enum ScorerSpec: Hashable, Sendable, Codable {
    /// Exact match on result fields such as `decisions.choice`.
    case exact(fields: [String])
    /// Weighted checks; the case passes when the score reaches `passThreshold`.
    case rubric(checks: [RubricCheckSpec], passThreshold: Double)

    private enum CodingKeys: String, CodingKey { case kind, fields, checks, passThreshold }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "exact": self = .exact(fields: try c.decode([String].self, forKey: .fields))
        case "rubric":
            self = .rubric(
                checks: try c.decode([RubricCheckSpec].self, forKey: .checks),
                passThreshold: try c.decodeIfPresent(Double.self, forKey: .passThreshold) ?? 1)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown scorer kind \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exact(let fields):
            try c.encode("exact", forKey: .kind)
            try c.encode(fields, forKey: .fields)
        case .rubric(let checks, let threshold):
            try c.encode("rubric", forKey: .kind)
            try c.encode(checks, forKey: .checks)
            try c.encode(threshold, forKey: .passThreshold)
        }
    }
}

/// One rubric check as authored in a charter. `kind` is interpreted by `AryaEval`
/// (`matchesExpected`, `exists`, `absent`, `equals`, `contains`).
public struct RubricCheckSpec: Hashable, Sendable, Codable {
    public var kind: String
    public var path: String
    public var value: JSONValue?
    public var weight: Double

    public init(kind: String, path: String, value: JSONValue? = nil, weight: Double = 1) {
        self.kind = kind
        self.path = path
        self.value = value
        self.weight = weight
    }

    private enum CodingKeys: String, CodingKey { case kind, path, value, weight }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        path = try c.decode(String.self, forKey: .path)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value)
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1
    }
}
