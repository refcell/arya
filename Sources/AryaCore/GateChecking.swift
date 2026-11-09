/// Asks whether a proposal may go live. The runtime calls it; `Arya` wires it to `AryaEval`,
/// which sits above the runtime (ARCHITECTURE.md, "Modules").
public protocol GateChecking: Sendable {
    func check(_ request: GateCheckRequest) async throws -> GateCheckVerdict
}

/// A gate check: rehearse `candidateVersion` of a steward's charter on a casebook version and
/// compare it with the baseline.
public struct GateCheckRequest: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var proposal: ProposalID
    public var candidateVersion: Int
    /// The casebook's content hash.
    public var casebookVersion: String

    public init(
        steward: StewardID, proposal: ProposalID, candidateVersion: Int, casebookVersion: String
    ) {
        self.steward = steward
        self.proposal = proposal
        self.candidateVersion = candidateVersion
        self.casebookVersion = casebookVersion
    }

    private enum CodingKeys: String, CodingKey {
        case steward, proposal, candidateVersion, casebookVersion
    }
}

/// The result of a gate check (decision 0017).
public struct GateCheckVerdict: Hashable, Sendable, Codable {
    public var passed: Bool
    /// Nil when there was no baseline rehearsal.
    public var baselineMean: Double?
    public var candidateMean: Double
    /// Ids of cases that passed in every baseline sample and failed in every candidate sample.
    public var regressions: [CaseID]
    /// A short, deterministic explanation.
    public var reason: String

    public init(
        passed: Bool, baselineMean: Double?, candidateMean: Double, regressions: [CaseID],
        reason: String
    ) {
        self.passed = passed
        self.baselineMean = baselineMean
        self.candidateMean = candidateMean
        self.regressions = regressions
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case passed, baselineMean, candidateMean, regressions, reason
    }
}

/// A gate that refuses everything. The safe default until a real gate is wired.
public struct RefusingGate: GateChecking {
    public init() {}

    public func check(_ request: GateCheckRequest) async throws -> GateCheckVerdict {
        GateCheckVerdict(
            passed: false, baselineMean: nil, candidateMean: 0, regressions: [],
            reason: "no gate configured")
    }
}
