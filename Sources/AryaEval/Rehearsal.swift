import AryaCore

/// What to rehearse: a steward's charter version on one casebook version.
public struct RehearsalRequest: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var charterVersion: Int
    public var casebookVersion: String
    /// Runs per case (`gate.samples`), at least 1.
    public var samples: Int
    /// The proposal whose candidate charter is rehearsed; `nil` for the live charter. Only
    /// rehearsals without a proposal serve as gate baselines.
    public var proposal: ProposalID?

    public init(
        steward: StewardID, charterVersion: Int, casebookVersion: String, samples: Int = 1,
        proposal: ProposalID? = nil
    ) {
        self.steward = steward
        self.charterVersion = charterVersion
        self.casebookVersion = casebookVersion
        self.samples = max(1, samples)
        self.proposal = proposal
    }

    enum CodingKeys: String, CodingKey {
        case steward, charterVersion, casebookVersion, samples, proposal
    }
}

/// The scores of one case over every sample, in sample order.
public struct CaseOutcome: Hashable, Sendable, Codable {
    public var caseID: CaseID
    public var samples: [CaseScore]
    /// True when a tool read had no recorded answer (decision 0015).
    public var leak: Bool

    public init(caseID: CaseID, samples: [CaseScore], leak: Bool = false) {
        self.caseID = caseID
        self.samples = samples
        self.leak = leak
    }

    enum CodingKeys: String, CodingKey {
        case caseID = "case"
        case samples, leak
    }
}

/// A finished rehearsal, with outcomes sorted by case id.
public struct RehearsalResult: Hashable, Sendable, Codable {
    public var id: RehearsalID?
    public var request: RehearsalRequest
    public var outcomes: [CaseOutcome]

    public init(id: RehearsalID? = nil, request: RehearsalRequest, outcomes: [CaseOutcome]) {
        self.id = id
        self.request = request
        self.outcomes = outcomes.sorted { $0.caseID < $1.caseID }
    }

    enum CodingKeys: String, CodingKey {
        case id, request, outcomes
    }
}

/// Runs a steward over a casebook offline and scores each case. Never executes actions.
/// `charter` is the charter rehearsed: the live one, or a proposal's candidate.
public protocol Rehearser: Sendable {
    func rehearse(_ request: RehearsalRequest, charter: Charter) async throws -> RehearsalResult
}

/// Placeholder until rehearsal runs land.
public struct StubRehearser: Rehearser {
    public init() {}

    public func rehearse(
        _ request: RehearsalRequest, charter: Charter
    ) async throws -> RehearsalResult {
        throw EvalError.notImplemented("rehearsal")
    }
}
