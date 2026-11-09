/// How much an action could go wrong.
public enum Risk: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case low, medium, high

    public static func < (a: Risk, b: Risk) -> Bool { a.rank < b.rank }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

extension Risk {
    /// The risk of an action kind no charter entry names (decision 0037): labeling and
    /// read-only kinds are low, outbound communication medium, irreversible or money-moving
    /// kinds high.
    public static let defaults: [String: Risk] = [
        "label": .low, "route": .low, "tag": .low, "note": .low,
        "reply": .medium, "message": .medium, "email": .medium,
        "refund": .high, "close": .high, "delete": .high, "pay": .high, "merge": .high,
    ]

    /// `defaults[kind]`, else `medium`.
    public static func `default`(forKind kind: String) -> Risk { defaults[kind] ?? .medium }
}

extension Policy {
    /// The risk of an action (decision 0037). The most specific `risk` entry wins (action and
    /// binding, then action, then binding alone; first listed among equals), where an entry's
    /// action is a kind or `routine:<name>`. With no entry, the kind's default
    /// (`Risk.default(forKind:)`). An adapter's `hint` can raise the result, never lower it.
    public func risk(
        ofAction kind: String, binding: String? = nil, routineName: String? = nil,
        hint: Risk? = nil
    ) -> Risk {
        let kinds = Set([kind] + (routineName.map { ["routine:\($0)"] } ?? []))
        func names(_ rule: RiskRule) -> Bool { rule.action.map(kinds.contains) == true }
        let both = risk.first { names($0) && $0.binding != nil && $0.binding == binding }
        let byAction = risk.first { names($0) && $0.binding == nil }
        let byBinding = risk.first {
            $0.action == nil && $0.binding != nil && $0.binding == binding
        }
        let base = (both ?? byAction ?? byBinding)?.level ?? Risk.default(forKind: kind)
        return max(base, hint ?? .low)
    }
}

/// How far a steward may act on its own (decision 0037).
public enum Autonomy: String, Hashable, Sendable, Codable, CaseIterable {
    /// Proposes nothing it would act on: every action is recorded and refused.
    case observe
    /// Every action waits for a person.
    case suggest
    /// Low-risk actions run; others wait.
    case actLow = "act_low"
    /// Low- and medium-risk actions run; high-risk ones wait.
    case actMedium = "act_medium"
}

/// One `policy.risk[]` entry: the risk of an action kind (or `routine:<name>`), optionally only
/// through one binding; with no action, every action through the binding.
public struct RiskRule: Hashable, Sendable, Codable {
    public var action: String?
    public var binding: String?
    public var level: Risk

    public init(action: String? = nil, binding: String? = nil, level: Risk) {
        self.action = action
        self.binding = binding
        self.level = level
    }

    private enum CodingKeys: String, CodingKey { case action, binding, level }
}
