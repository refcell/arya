// Agents propose, arya disposes (decision 0005). The classifier decides, for each proposed
// action, whether arya executes it (`auto`), holds it for a person (`ask`), or refuses it
// (`deny`). It is a pure function of the action and the charter's policy and bindings, so every
// disposition replays exactly.

/// What arya does with a proposed action.
public enum ActionDisposition: String, Codable, Sendable, CaseIterable {
    /// Execute through the binding or routine without asking.
    case auto
    /// Hold in the approval queue until a person grants or denies it.
    case ask
    /// Refuse and record `action.rejected`.
    case deny
}

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

    /// Creates a policy view of an action.
    public init(kind: String, binding: String?) {
        self.kind = kind
        self.binding = binding
    }
}

/// A disposition and the reason recorded with it.
public struct PolicyVerdict: Sendable, Hashable {
    /// The disposition.
    public var disposition: ActionDisposition
    /// A short, stable explanation, for example `rule:label` or `default`.
    public var reason: String

    /// Creates a verdict.
    public init(disposition: ActionDisposition, reason: String) {
        self.disposition = disposition
        self.reason = reason
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
        if let refusal = structuralRefusal(action) {
            return PolicyVerdict(disposition: .deny, reason: refusal)
        }
        if let rule = rules.first(where: { $0.matches(action) }) {
            return PolicyVerdict(disposition: rule.decision, reason: rule.label)
        }
        return PolicyVerdict(disposition: defaultDisposition, reason: "default")
    }

    private func structuralRefusal(_ action: PolicyAction) -> String? {
        if action.kind.isEmpty { return "empty_kind" }
        if action.kind == Self.routineKind { return nil }
        guard let binding = action.binding, !binding.isEmpty else { return "no_binding" }
        guard let allowed = bindingActions[binding] else { return "unknown_binding:\(binding)" }
        guard allowed.contains(action.kind) else {
            return "not_allowed:\(binding).\(action.kind)"
        }
        return nil
    }
}
