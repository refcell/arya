import AryaCore

// Agents propose, arya disposes (decision 0005). The classifier decides, for each proposed
// action, whether arya executes it (`auto`), holds it for a person (`ask`), or refuses it
// (`deny`). It is a pure function of the action and the charter's policy and bindings, so every
// disposition replays exactly.

/// What arya does with a proposed action: `auto`, `ask`, or `deny` (core's `PolicyDecision`).
public typealias ActionDisposition = PolicyDecision

/// One `policy.rules[]` entry: a disposition for an action kind, optionally only through one
/// binding.
public struct PolicyRule: Sendable, Hashable {
    /// The action kind the rule matches, for example `label`.
    public var action: String
    /// When set, the rule matches only actions through this binding.
    public var binding: String?
    /// The disposition for matching actions.
    public var decision: ActionDisposition

    /// Creates a rule.
    public init(action: String, binding: String? = nil, decision: ActionDisposition) {
        self.action = action
        self.binding = binding
        self.decision = decision
    }

    func matches(_ action: PolicyAction) -> Bool {
        self.action == action.kind && (binding == nil || binding == action.binding)
    }

    var label: String { binding.map { "rule:\($0).\(action)" } ?? "rule:\(action)" }
}

/// The parts of a proposed action that policy looks at.
public struct PolicyAction: Sendable, Hashable {
    /// The action kind, for example `comment` or `routine`.
    public var kind: String
    /// The charter binding that would carry it out; `nil` for `routine`.
    public var binding: String?
    /// For `routine`: the routine name (`params.name`).
    public var routineName: String?
    /// For `routine`: the routine's live version, `nil` when it has none.
    public var routineVersion: String?
    /// The adapter's risk hint.
    public var riskHint: Risk?

    /// Creates a policy view of an action.
    public init(
        kind: String, binding: String?, routineName: String? = nil,
        routineVersion: String? = nil, riskHint: Risk? = nil
    ) {
        self.riskHint = riskHint
        self.kind = kind
        self.binding = binding
        self.routineName = routineName
        self.routineVersion = routineVersion
    }
}

/// A disposition and the reason recorded with it.
public struct PolicyVerdict: Sendable, Hashable {
    /// The disposition.
    public var disposition: ActionDisposition
    /// A short, stable explanation, for example `rule:label`, `default`, or
    /// `autonomy:act_low:medium`.
    public var reason: String
    /// The resolved risk, when the steward has an autonomy level.
    public var risk: Risk?
    /// The autonomy level that shaped the verdict.
    public var autonomy: Autonomy?

    /// Creates a verdict.
    public init(
        disposition: ActionDisposition, reason: String, risk: Risk? = nil,
        autonomy: Autonomy? = nil
    ) {
        self.disposition = disposition
        self.reason = reason
        self.risk = risk
        self.autonomy = autonomy
    }
}

/// A charter's approval policy together with the action kinds each binding allows.
public struct ActionPolicy: Sendable, Hashable {
    /// The action kind that runs a routine; it needs no binding.
    public static let routineKind = "routine"

    /// Disposition for kinds no rule mentions; `ask` unless the charter says otherwise
    /// (decision 0018).
    public var defaultDisposition: ActionDisposition
    /// Rules in charter order; the first rule for a kind wins.
    public var rules: [PolicyRule]
    /// For each binding id, the action kinds arya may execute through it.
    public var bindingActions: [String: Set<String>]
    /// The steward's autonomy level; nil keeps the rules and default alone.
    public var autonomy: Autonomy?
    /// Risk levels in charter order.
    public var riskRules: [RiskRule] = []

    /// Creates a policy. `defaultDisposition` is `ask` when omitted.
    public init(
        defaultDisposition: ActionDisposition = .ask, rules: [PolicyRule] = [],
        bindingActions: [String: Set<String>] = [:]
    ) {
        self.defaultDisposition = defaultDisposition
        self.rules = rules
        self.bindingActions = bindingActions
    }

    /// Classifies one proposed action.
    ///
    /// Order: an empty kind, an unknown binding, or a kind the binding does not list is denied
    /// (arya could not carry it out); then the first matching rule (kind, and binding when the
    /// rule names one); then the default.
    public func classify(_ action: PolicyAction) -> PolicyVerdict {
        let base = classifyByRules(action)
        guard let autonomy else { return base }
        return Self.limit(base, by: autonomy, risk: risk(of: action))
    }

    /// The risk of an action (decision 0037): the most specific `policy.risk` entry (action
    /// and binding, then action, then binding alone; first listed among equals), `medium`
    /// when none matches, raised (never lowered) by the adapter's hint.
    public func risk(of action: PolicyAction) -> Risk {
        let name =
            action.kind == Self.routineKind ? action.routineName.map { "routine:\($0)" } : nil
        let kinds = Set([action.kind] + (name.map { [$0] } ?? []))
        let both = riskRules.first {
            $0.action.map(kinds.contains) == true && $0.binding != nil
                && $0.binding == action.binding
        }
        let byAction = riskRules.first {
            $0.action.map(kinds.contains) == true && $0.binding == nil
        }
        let byBinding = riskRules.first {
            $0.action == nil && $0.binding != nil && $0.binding == action.binding
        }
        let charter = (both ?? byAction ?? byBinding)?.level ?? .medium
        return max(charter, action.riskHint ?? .low)
    }

    /// What `autonomy` allows for `risk`.
    public static func allowed(_ autonomy: Autonomy, risk: Risk) -> ActionDisposition {
        switch autonomy {
        case .observe: .deny
        case .suggest: .ask
        case .actLow: risk == .low ? .auto : .ask
        case .actMedium: risk == .high ? .ask : .auto
        }
    }

    /// A rule may only tighten what autonomy allows; with no rule, autonomy decides (except an
    /// unlisted routine, which still asks).
    static func limit(_ base: PolicyVerdict, by autonomy: Autonomy, risk: Risk) -> PolicyVerdict {
        func verdict(_ disposition: ActionDisposition, _ reason: String) -> PolicyVerdict {
            PolicyVerdict(disposition: disposition, reason: reason, risk: risk, autonomy: autonomy)
        }
        if base.disposition == .deny { return verdict(.deny, base.reason) }
        let allowed = allowed(autonomy, risk: risk)
        let label = "autonomy:\(autonomy.rawValue):\(risk.rawValue)"
        let ruled = base.reason.hasPrefix("rule:") || base.reason == "routine_default"
        guard ruled else { return verdict(allowed, label) }
        return strictness(allowed) > strictness(base.disposition)
            ? verdict(allowed, label) : verdict(base.disposition, base.reason)
    }

    private static func strictness(_ disposition: ActionDisposition) -> Int {
        switch disposition {
        case .auto: 0
        case .ask: 1
        case .deny: 2
        }
    }

    private func classifyByRules(_ action: PolicyAction) -> PolicyVerdict {
        if action.kind == Self.routineKind { return classifyRoutine(action) }
        if let refusal = structuralRefusal(action) {
            return PolicyVerdict(disposition: .deny, reason: refusal)
        }
        if let rule = rules.first(where: { $0.matches(action) }) {
            return PolicyVerdict(disposition: rule.decision, reason: rule.label)
        }
        return PolicyVerdict(disposition: defaultDisposition, reason: "default")
    }

    /// Routines are approved per name and version (decision 0032): a `routine:<name>@<version>`
    /// rule decides that version; a `routine:<name>` rule may only deny (every version); any
    /// other routine asks, whatever `policy.default` or a kind-level `routine` rule says, so a
    /// new version asks until the charter names it. A routine with no name or no live version
    /// is denied (arya could not run it).
    private func classifyRoutine(_ action: PolicyAction) -> PolicyVerdict {
        guard let name = action.routineName, !name.isEmpty else {
            return PolicyVerdict(disposition: .deny, reason: "no_routine_name")
        }
        guard let version = action.routineVersion else {
            return PolicyVerdict(disposition: .deny, reason: "unknown_routine:\(name)")
        }
        let pinned = "routine:\(name)@\(version)"
        if let rule = rules.first(where: { $0.action == pinned }) {
            return PolicyVerdict(disposition: rule.decision, reason: "rule:\(pinned)")
        }
        let named = "routine:\(name)"
        if rules.contains(where: { $0.action == named && $0.decision == .deny }) {
            return PolicyVerdict(disposition: .deny, reason: "rule:\(named)")
        }
        return PolicyVerdict(disposition: .ask, reason: "routine_default")
    }

    private func structuralRefusal(_ action: PolicyAction) -> String? {
        if action.kind.isEmpty { return "empty_kind" }
        guard let binding = action.binding, !binding.isEmpty else { return "no_binding" }
        guard let allowed = bindingActions[binding] else { return "unknown_binding:\(binding)" }
        guard allowed.contains(action.kind) else {
            return "not_allowed:\(binding).\(action.kind)"
        }
        return nil
    }
}

extension ActionPolicy {
    /// The policy of a charter: its default and rules, and the actions each binding allows.
    public init(charter: Charter) {
        self.init(
            defaultDisposition: charter.policy.default,
            rules: charter.policy.rules.map {
                PolicyRule(action: $0.action, binding: $0.binding, decision: $0.decision)
            },
            bindingActions: Dictionary(
                charter.bindings.map { ($0.id, Set($0.actions)) },
                uniquingKeysWith: { first, _ in first }))
        autonomy = charter.autonomy
        riskRules = charter.policy.risk
    }
}
