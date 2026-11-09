import AryaCore

/// Payload of `rehearsal.started`.
public struct RehearsalStartedPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var rehearsal: RehearsalID
    public var charterVersion: Int
    public var casebookVersion: String
    public var cases: Int
    public var samples: Int

    enum CodingKeys: String, CodingKey {
        case v, rehearsal, charterVersion, casebookVersion, cases, samples
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

    enum CodingKeys: String, CodingKey {
        case v, rehearsal
        case caseID = "case"
        case runs, scores, leak
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
