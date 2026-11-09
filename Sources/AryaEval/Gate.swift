/// A proposal to be gated: a candidate charter version rehearsed against the live version.
public struct GateRequest: Hashable, Sendable, Codable {
    public var steward: String
    public var proposal: String
    public var candidateVersion: Int
    public var casebookVersion: String

    public init(steward: String, proposal: String, candidateVersion: Int, casebookVersion: String) {
        self.steward = steward
        self.proposal = proposal
        self.candidateVersion = candidateVersion
        self.casebookVersion = casebookVersion
    }

    enum CodingKeys: String, CodingKey {
        case steward, proposal, candidateVersion, casebookVersion
    }
}

/// The result of a gate check (decision 0017).
public struct GateVerdict: Hashable, Sendable, Codable {
    public var passed: Bool
    public var baselineMean: Double?
    public var candidateMean: Double
    /// Case ids that passed in every baseline sample and failed in every candidate sample.
    public var regressions: [String]
    public var reason: String

    public init(
        passed: Bool, baselineMean: Double?, candidateMean: Double, regressions: [String],
        reason: String
    ) {
        self.passed = passed
        self.baselineMean = baselineMean
        self.candidateMean = candidateMean
        self.regressions = regressions
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case passed, baselineMean, candidateMean, regressions, reason
    }
}

/// Stand-in for `AryaCore.GateChecking` until the ledger lane publishes it; `Gate` will conform
/// to the core protocol then and this one will be deleted. The prefix avoids a name clash in
/// modules that import both.
public protocol EvalGateChecking: Sendable {
    func check(_ request: GateRequest) async throws -> GateVerdict
}

/// Decides whether a proposal may go live.
public protocol Gate: EvalGateChecking {}

/// Placeholder gate that refuses every proposal, so nothing goes live untested.
public struct StubGate: Gate {
    public init() {}

    public func check(_ request: GateRequest) async throws -> GateVerdict {
        GateVerdict(
            passed: false, baselineMean: nil, candidateMean: 0, regressions: [],
            reason: "gate not implemented")
    }
}
