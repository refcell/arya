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
