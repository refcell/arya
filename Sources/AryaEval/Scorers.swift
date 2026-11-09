extension EvalValue {
    /// Values at a dotted path. Arrays along the way fan out, so `actions.kind` on
    /// `{"actions":[{"kind":"label"},{"kind":"comment"}]}` gives `["label", "comment"]`.
    /// Missing members contribute nothing.
    public func values(at path: String) -> [EvalValue] {
        var current: [EvalValue] = [self]
        for key in path.split(separator: ".").map(String.init) {
            current = current.flatMap { value -> [EvalValue] in
                switch value {
                case .array(let items): return items.compactMap { $0[key] }
                default: return value[key].map { [$0] } ?? []
                }
            }
        }
        return current
    }
}

/// Exact match on chosen fields. The score is the share of fields whose values match, in
/// order; the case passes only when every field matches.
public struct ExactScorer: Scorer {
    public var fields: [String]

    public init(fields: [String]) {
        self.fields = fields
    }

    public func score(expected: EvalValue, actual: EvalValue) -> CaseScore {
        guard !fields.isEmpty else {
            return CaseScore(value: 0, passed: false, notes: ["no fields to compare"])
        }
        let failed = fields.filter { expected.values(at: $0) != actual.values(at: $0) }
        let value = Double(fields.count - failed.count) / Double(fields.count)
        return CaseScore(
            value: value, passed: failed.isEmpty, notes: failed.map { "\($0) differs" })
    }
}

/// One weighted check in a rubric.
public struct RubricCheck: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// The values at `path` in the actual result equal those in the expected result.
        case matchesExpected
        /// The actual result has at least one value at `path`.
        case exists
        /// The actual result has no value at `path`.
        case absent
        /// Some value at `path` equals `value`.
        case equals
        /// Some string at `path` contains the string `value`.
        case contains
    }

    public var kind: Kind
    public var path: String
    public var value: EvalValue?
    public var weight: Double

    public init(kind: Kind, path: String, value: EvalValue? = nil, weight: Double = 1) {
        self.kind = kind
        self.path = path
        self.value = value
        self.weight = weight
    }

    enum CodingKeys: String, CodingKey {
        case kind, path, value, weight
    }

    func holds(expected: EvalValue, actual: EvalValue) -> Bool {
        let found = actual.values(at: path)
        switch kind {
        case .matchesExpected: return found == expected.values(at: path)
        case .exists: return !found.isEmpty
        case .absent: return found.isEmpty
        case .equals: return value.map(found.contains) ?? false
        case .contains:
            guard case .string(let needle) = value else { return false }
            return found.contains { item in
                if case .string(let text) = item { return text.contains(needle) }
                return false
            }
        }
    }
}

/// Weighted checks on result fields. The score is the passed weight over the total weight;
/// the case passes when the score reaches `passThreshold`.
public struct RubricScorer: Scorer {
    public var checks: [RubricCheck]
    public var passThreshold: Double

    public init(checks: [RubricCheck], passThreshold: Double = 1) {
        self.checks = checks
        self.passThreshold = passThreshold
    }

    public func score(expected: EvalValue, actual: EvalValue) -> CaseScore {
        let total = checks.reduce(0) { $0 + max(0, $1.weight) }
        guard total > 0 else {
            return CaseScore(value: 0, passed: false, notes: ["rubric has no weight"])
        }
        var earned = 0.0
        var notes: [String] = []
        for check in checks where check.weight > 0 {
            if check.holds(expected: expected, actual: actual) {
                earned += check.weight
            } else {
                notes.append("\(check.kind.rawValue) \(check.path) failed")
            }
        }
        let value = earned / total
        return CaseScore(value: value, passed: value >= passThreshold, notes: notes)
    }
}
