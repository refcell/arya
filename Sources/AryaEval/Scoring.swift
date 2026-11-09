import AryaCore

/// The score of one case: a value in `0...1` and whether the case passed.
public struct CaseScore: Hashable, Sendable, Codable {
    public var value: Double
    public var passed: Bool
    /// Short, deterministic notes explaining the score (failed fields or checks).
    public var notes: [String]
    /// Each check the scorer made, for the app; absent in scores recorded before checks were.
    public var checks: [CheckResult]?

    public init(value: Double, passed: Bool, notes: [String] = [], checks: [CheckResult]? = nil) {
        self.value = value
        self.passed = passed
        self.notes = notes
        self.checks = checks
    }

    enum CodingKeys: String, CodingKey {
        case value, passed, notes, checks
    }
}

/// One check a scorer made: a field compared, a rubric check, or a judge's verdict.
public struct CheckResult: Hashable, Sendable, Codable {
    /// What was checked, in words: `decisions.choice matches expected`, `judge fake`.
    public var label: String
    public var passed: Bool
    public var weight: Double
    /// The outcome in words, shown verbatim: `expected billing, got how-to`.
    public var text: String

    public init(label: String, passed: Bool, weight: Double = 1, text: String) {
        self.label = label
        self.passed = passed
        self.weight = weight
        self.text = text
    }
}

extension CaseScore {
    /// One line for the app: `passed (1)` or `failed (0.67): decisions.choice: expected
    /// billing, got how-to`; failed checks (or notes, for older scores) after the colon.
    public var text: String {
        let head = "\(passed ? "passed" : "failed") (\(ResultText.value(.double(rounded))))"
        let failed =
            checks.map { $0.filter { !$0.passed }.map { "\($0.label): \($0.text)" } } ?? notes
        return failed.isEmpty ? head : head + ": " + failed.joined(separator: "; ")
    }

    var rounded: Double { (value * 100).rounded() / 100 }

    /// Lists values found at a path in words.
    static func words(_ values: [JSONValue]) -> String {
        values.isEmpty ? "nothing" : values.map(ResultText.value).joined(separator: ", ")
    }
}

/// Scores what a steward did on a case against the case's expected result.
public protocol Scorer: Sendable {
    func score(expected: JSONValue, actual: JSONValue) -> CaseScore
}

/// Placeholder scorer that fails every case, so an unconfigured scorer can never pass a gate.
public struct StubScorer: Scorer {
    public init() {}

    public func score(expected: JSONValue, actual: JSONValue) -> CaseScore {
        CaseScore(value: 0, passed: false, notes: ["scorer not implemented"])
    }
}
