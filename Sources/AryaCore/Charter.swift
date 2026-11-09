import Foundation

/// A steward's outcome, metric, guardrails, bindings, triggers, approval policy, and effort.
/// Authored as JSON (see ARCHITECTURE.md, "Charters and cases") and recorded into the ledger.
/// The charter document carries no version number: versions are ledger facts.
public struct Charter: Hashable, Sendable, Codable {
    /// Schema version of the document; always 1.
    public var v: Int
    public var id: StewardID
    public var name: String
    public var outcome: String
    public var metric: Metric
    public var guardrails: [String]
    public var bindings: [CharterBinding]
    public var triggers: [Trigger]
    public var policy: Policy
    /// The adapter profile name in `adapters.json`.
    public var adapter: String
    public var effort: Effort
    public var crew: Crew
    public var limits: Limits
    public var scorer: ScorerSpec
    public var gate: GateConfig
    /// How far the steward may act on its own; nil keeps the policy alone (decision 0037).
    public var autonomy: Autonomy?

    public init(
        id: StewardID, name: String, outcome: String, metric: Metric,
        guardrails: [String] = [], bindings: [CharterBinding] = [],
        triggers: [Trigger] = [.manual], policy: Policy = Policy(), adapter: String,
        effort: Effort = .medium, crew: Crew = Crew(), limits: Limits = Limits(),
        scorer: ScorerSpec = .exact(fields: ["decisions.choice"]), gate: GateConfig = GateConfig()
    ) {
        v = 1
        self.id = id
        self.name = name
        self.outcome = outcome
        self.metric = metric
        self.guardrails = guardrails
        self.bindings = bindings
        self.triggers = triggers
        self.policy = policy
        self.adapter = adapter
        self.effort = effort
        self.crew = crew
        self.limits = limits
        self.scorer = scorer
        self.gate = gate
    }

    private enum CodingKeys: String, CodingKey {
        case v, id, name, outcome, metric, guardrails, bindings, triggers, policy, adapter
        case effort, crew, limits, scorer, gate, autonomy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(StewardID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        outcome = try c.decode(String.self, forKey: .outcome)
        metric = try c.decode(Metric.self, forKey: .metric)
        guardrails = try c.decodeIfPresent([String].self, forKey: .guardrails) ?? []
        bindings = try c.decodeIfPresent([CharterBinding].self, forKey: .bindings) ?? []
        triggers = try c.decodeIfPresent([Trigger].self, forKey: .triggers) ?? [.manual]
        policy = try c.decodeIfPresent(Policy.self, forKey: .policy) ?? Policy()
        adapter = try c.decode(String.self, forKey: .adapter)
        effort = try c.decodeIfPresent(Effort.self, forKey: .effort) ?? .medium
        crew = try c.decodeIfPresent(Crew.self, forKey: .crew) ?? Crew()
        limits = try c.decodeIfPresent(Limits.self, forKey: .limits) ?? Limits()
        scorer = try c.decode(ScorerSpec.self, forKey: .scorer)
        gate = try c.decodeIfPresent(GateConfig.self, forKey: .gate) ?? GateConfig()
        autonomy = try c.decodeIfPresent(Autonomy.self, forKey: .autonomy)
    }

    /// Decodes and validates a charter document.
    public static func load(from data: Data) throws -> Charter {
        let charter: Charter
        do {
            charter = try JSONDecoder().decode(Charter.self, from: data)
        } catch {
            throw CharterError.malformed(String(describing: error))
        }
        let issues = charter.validate()
        if !issues.isEmpty { throw CharterError.invalid(issues) }
        return charter
    }

    /// The binding with `id`, if any.
    public func binding(_ id: String) -> CharterBinding? {
        bindings.first { $0.id == id }
    }
}

/// How a steward's success is measured.
public struct Metric: Hashable, Sendable, Codable {
    public enum Direction: String, Hashable, Sendable, Codable { case up, down }

    public var name: String
    /// Free-form unit such as `ratio`, `count`, or `seconds`.
    public var unit: String
    public var direction: Direction
    public var target: Double?

    public init(name: String, unit: String, direction: Direction, target: Double? = nil) {
        self.name = name
        self.unit = unit
        self.direction = direction
        self.target = target
    }

    private enum CodingKeys: String, CodingKey { case name, unit, direction, target }
}

/// Effort level; each adapter maps it to a model and reasoning budget.
public enum Effort: String, Hashable, Sendable, Codable, CaseIterable {
    case low, medium, high
}

/// Fan-out settings for crews.
public struct Crew: Hashable, Sendable, Codable {
    public var maxParallel: Int

    public init(maxParallel: Int = 1) { self.maxParallel = maxParallel }

    private enum CodingKeys: String, CodingKey { case maxParallel }
}

/// Per-run limits.
public struct Limits: Hashable, Sendable, Codable {
    public var maxTurns: Int
    public var timeoutSeconds: Int
    public var maxCostMicros: Int64

    public init(maxTurns: Int = 40, timeoutSeconds: Int = 900, maxCostMicros: Int64 = 2_000_000) {
        self.maxTurns = maxTurns
        self.timeoutSeconds = timeoutSeconds
        self.maxCostMicros = maxCostMicros
    }

    private enum CodingKeys: String, CodingKey { case maxTurns, timeoutSeconds, maxCostMicros }
}

/// Gate settings (decision 0017).
public struct GateConfig: Hashable, Sendable, Codable {
    /// Runs per case in each rehearsal, at least 1.
    public var samples: Int
    /// How far below the baseline mean a candidate's mean may fall, at least 0.
    public var tolerance: Double

    public init(samples: Int = 1, tolerance: Double = 0) {
        self.samples = samples
        self.tolerance = tolerance
    }

    private enum CodingKeys: String, CodingKey { case samples, tolerance }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent(Int.self, forKey: .samples) ?? 1
        tolerance = try c.decodeIfPresent(Double.self, forKey: .tolerance) ?? 0
    }
}
