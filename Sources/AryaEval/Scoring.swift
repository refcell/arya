import AryaCore

/// The score of one case: a value in `0...1` and whether the case passed.
public struct CaseScore: Hashable, Sendable, Codable {
    public var value: Double
    public var passed: Bool
    /// Short, deterministic notes explaining the score (failed fields or checks).
    public var notes: [String]

    public init(value: Double, passed: Bool, notes: [String] = []) {
        self.value = value
        self.passed = passed
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case value, passed, notes
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
