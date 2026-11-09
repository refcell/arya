import AryaCore

/// Payload of `rehearsal.started`.
public struct RehearsalStartedPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var rehearsal: RehearsalID
    public var charterVersion: Int
    public var casebookVersion: String
    public var cases: Int
    public var samples: Int
    public var proposal: ProposalID?
    public var routine: RoutineCandidate?

    enum CodingKeys: String, CodingKey {
        case v, rehearsal, charterVersion, casebookVersion, cases, samples, proposal, routine
    }
}

/// Payload of `rehearsal.case.scored`: every sample of one case.
public struct RehearsalCaseScoredPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var rehearsal: RehearsalID
    public var caseID: CaseID
    /// The run of each sample, in sample order; `nil` where the run could not start.
    public var runs: [RunID?]
    public var scores: [CaseScore]
    public var leak: Bool
    /// Each sample's result in the shape of `expected`; `nil` where the run failed. Absent in
    /// events recorded before results were kept.
    public var results: [JSONValue?]?

    enum CodingKeys: String, CodingKey {
        case v, rehearsal
        case caseID = "case"
        case runs, scores, leak, results
    }
}

/// Payload of `rehearsal.finished`.
public struct RehearsalFinishedPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var rehearsal: RehearsalID
    public var meanScore: Double
    /// Cases that passed in every sample.
    public var passed: Int
    public var leaks: Int

    enum CodingKeys: String, CodingKey {
        case v, rehearsal, meanScore, passed, leaks
    }
}
