import AryaCore

/// What to rehearse: a steward's charter version on one casebook version.
public struct RehearsalRequest: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var charterVersion: Int
    public var casebookVersion: String
    /// Runs per case (`gate.samples`), at least 1.
    public var samples: Int

    public init(
        steward: StewardID, charterVersion: Int, casebookVersion: String, samples: Int = 1
    ) {
        self.steward = steward
        self.charterVersion = charterVersion
        self.casebookVersion = casebookVersion
        self.samples = max(1, samples)
    }

    enum CodingKeys: String, CodingKey {
        case steward, charterVersion, casebookVersion, samples
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
    public var request: RehearsalRequest
    public var outcomes: [CaseOutcome]

    public init(request: RehearsalRequest, outcomes: [CaseOutcome]) {
        self.request = request
        self.outcomes = outcomes.sorted { $0.caseID < $1.caseID }
    }

    enum CodingKeys: String, CodingKey {
        case request, outcomes
    }
}

/// Runs a steward over a casebook offline and scores each case. Never executes actions.
public protocol Rehearser: Sendable {
    func rehearse(_ request: RehearsalRequest) async throws -> RehearsalResult
}

/// Placeholder until rehearsal runs land.
public struct StubRehearser: Rehearser {
    public init() {}

    public func rehearse(_ request: RehearsalRequest) async throws -> RehearsalResult {
        throw EvalError.notImplemented("rehearsal")
    }
}
