import AryaCore

extension JSONValue {
    /// Values at a dotted path. Arrays along the way fan out, so `actions.kind` on
    /// `{"actions":[{"kind":"label"},{"kind":"comment"}]}` gives `["label", "comment"]`.
    /// Missing members contribute nothing.
    public func values(at path: String) -> [JSONValue] {
        var current: [JSONValue] = [self]
        for key in path.split(separator: ".").map(String.init) {
            current = current.flatMap { value -> [JSONValue] in
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

    public func score(expected: JSONValue, actual: JSONValue) -> CaseScore {
        guard !fields.isEmpty else {
            return CaseScore(value: 0, passed: false, notes: ["no fields to compare"])
        }
        let failed = fields.filter { expected.values(at: $0) != actual.values(at: $0) }
        let value = Double(fields.count - failed.count) / Double(fields.count)
        let checks = fields.map { field in
            let want = expected.values(at: field)
            let have = actual.values(at: field)
            return CheckResult(
                label: "\(field) matches expected", passed: want == have,
                text: want == have
                    ? CaseScore.words(have)
                    : "expected \(CaseScore.words(want)), got \(CaseScore.words(have))")
        }
        return CaseScore(
            value: value, passed: failed.isEmpty, notes: failed.map { "\($0) differs" },
            checks: checks)
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
    public var value: JSONValue?
    public var weight: Double

    public init(kind: Kind, path: String, value: JSONValue? = nil, weight: Double = 1) {
        self.kind = kind
        self.path = path
        self.value = value
        self.weight = weight
    }

    enum CodingKeys: String, CodingKey {
        case kind, path, value, weight
    }

    /// The check in words: `decisions.choice matches expected`, `actions.kind is label`.
    public var label: String {
        let operand = value.map(ResultText.value) ?? "?"
        switch kind {
        case .matchesExpected: return "\(path) matches expected"
        case .exists: return "\(path) is present"
        case .absent: return "\(path) is absent"
        case .equals: return "\(path) is \(operand)"
        case .contains: return "\(path) contains \(operand)"
        }
    }

    func holds(expected: JSONValue, actual: JSONValue) -> Bool {
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

    public func score(expected: JSONValue, actual: JSONValue) -> CaseScore {
        let total = checks.reduce(0) { $0 + max(0, $1.weight) }
        guard total > 0 else {
            return CaseScore(value: 0, passed: false, notes: ["rubric has no weight"])
        }
        var earned = 0.0
        var notes: [String] = []
        var results: [CheckResult] = []
        for check in checks where check.weight > 0 {
            let holds = check.holds(expected: expected, actual: actual)
            if holds {
                earned += check.weight
            } else {
                notes.append("\(check.kind.rawValue) \(check.path) failed")
            }
            results.append(
                CheckResult(
                    label: check.label, passed: holds, weight: check.weight,
                    text: "found \(CaseScore.words(actual.values(at: check.path)))"))
        }
        let value = earned / total
        return CaseScore(
            value: value, passed: value >= passThreshold, notes: notes, checks: results)
    }
}

extension ScorerSpec {
    /// The scorer a charter asks for. Throws on a rubric check kind eval does not know.
    public func makeScorer() throws -> any Scorer {
        switch self {
        case .exact(let fields):
            return ExactScorer(fields: fields)
        case .rubric(let specs, let threshold):
            let checks = try specs.map { spec in
                guard let kind = RubricCheck.Kind(rawValue: spec.kind) else {
                    throw EvalError.unknownRubricCheck(spec.kind)
                }
                return RubricCheck(
                    kind: kind, path: spec.path, value: spec.value, weight: spec.weight)
            }
            return RubricScorer(checks: checks, passThreshold: threshold)
        }
    }
}
