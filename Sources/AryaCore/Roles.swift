/// One `policy.approvers[]` entry: the people who may approve actions of a kind (`*` for every
/// kind), optionally only through one binding. People are `local` (the person at this home)
/// or person binding ids such as `person:alex`.
public struct ApproverRule: Hashable, Sendable, Codable {
    /// An action kind, `routine:<name>`, or `*`.
    public var action: String
    /// Limits the rule to one binding; nil matches any binding.
    public var binding: String?
    /// Who may approve; never empty in a valid charter.
    public var people: [String]
    /// The rule in a person's words, for example "Refunds need the billing lead".
    public var note: String?

    public init(action: String, binding: String? = nil, people: [String], note: String? = nil) {
        self.action = action
        self.binding = binding
        self.people = people
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case action, binding, people, note }

    /// The wildcard action.
    public static let anyAction = "*"
}

/// Whether one person may approve one held action, and the rule that says so.
public enum ApprovalAuthority: Hashable, Sendable {
    /// No approver rule covers the action: anyone who can see the approval may decide it.
    case open
    /// A rule covers the action and lists the person.
    case allowed(ApproverRule)
    /// A rule covers the action and does not list the person.
    case refused(ApproverRule)

    /// True unless refused.
    public var permits: Bool {
        if case .refused = self { return false }
        return true
    }

    /// The rule that decided, if any.
    public var rule: ApproverRule? {
        switch self {
        case .open: nil
        case .allowed(let rule), .refused(let rule): rule
        }
    }
}

extension Policy {
    /// The approver rule for an action (most specific first: kind and binding, kind, `*` and
    /// binding, `*`; the first listed among equals). Nil when no rule covers it.
    public func approverRule(
        forAction kind: String, binding: String? = nil, routineName: String? = nil
    ) -> ApproverRule? {
        let kinds = Set([kind] + (routineName.map { ["routine:\($0)"] } ?? []))
        func exact(_ rule: ApproverRule) -> Bool { kinds.contains(rule.action) }
        func any(_ rule: ApproverRule) -> Bool { rule.action == ApproverRule.anyAction }
        func through(_ rule: ApproverRule) -> Bool {
            rule.binding != nil && rule.binding == binding
        }
        return approvers.first { exact($0) && through($0) }
            ?? approvers.first { exact($0) && $0.binding == nil }
            ?? approvers.first { any($0) && through($0) }
            ?? approvers.first { any($0) && $0.binding == nil }
    }

    /// The approver rule covering `action`, if any; a `routine` action is also matched by
    /// `routine:<params.name>`.
    public func approverRule(for action: ProposedAction) -> ApproverRule? {
        let routine = action.kind == "routine" ? action.params?["name"]?.stringValue : nil
        return approverRule(forAction: action.kind, binding: action.binding, routineName: routine)
    }

    /// Whether `person` may approve `action` under this policy.
    public func authority(of person: String, for action: ProposedAction) -> ApprovalAuthority {
        guard let rule = approverRule(for: action) else { return .open }
        return rule.people.contains(person) ? .allowed(rule) : .refused(rule)
    }
}
