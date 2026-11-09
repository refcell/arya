// View models for the improvement-loop commands (M2). Same `--json` contract as Models.swift.

/// The result of `arya casebook import`, and one row of `arya casebook list`.
struct CasebookRow: Codable, Sendable, Equatable {
    let name: String
    let steward: String
    /// SHA-256 of the normalized content; scores compare only within one version.
    let version: String
    let cases: Int

    enum CodingKeys: String, CodingKey { case name, steward, version, cases }
}

/// One case's result in a rehearsal.
struct RehearsedCase: Codable, Sendable, Equatable {
    let id: String
    let passed: Bool
    let score: Double
    /// True when the run tried a tool read the case had no recorded answer for.
    let leak: Bool

    enum CodingKeys: String, CodingKey { case id, passed, score, leak }
}

/// The result of `arya rehearse`.
struct RehearsalReport: Codable, Sendable, Equatable {
    let rehearsal: String
    let steward: String
    let casebook: String
    let passed: Int
    let total: Int
    /// Mean case score, 0 to 1.
    let score: Double
    /// Ids of the cases that did not pass, in casebook order.
    let failed: [String]
    let cases: [RehearsedCase]

    enum CodingKeys: String, CodingKey {
        case rehearsal, steward, casebook, passed, total, score, failed, cases
    }
}

/// The result of `arya correct`.
struct CorrectionReport: Codable, Sendable, Equatable {
    let steward: String
    let `case`: String
    let choice: String?
    let note: String?
    /// The memory note the correction became, if any.
    let memory: String?

    enum CodingKeys: String, CodingKey { case steward, `case`, choice, note, memory }
}

/// A proposal's state.
enum ProposalState: String, Codable, Sendable {
    case rehearsing, passed, failed, accepted, rejected, overridden
}

/// One row of `arya proposals`, and the result of `arya propose`.
struct ProposalRow: Codable, Sendable, Equatable {
    let id: String
    let steward: String
    /// `charter` or `routine`.
    let kind: String
    let state: ProposalState
    /// Mean scores of the live version and the candidate, once rehearsed.
    let baseline: Double?
    let candidate: Double?
    /// Cases that passed in every baseline sample and failed in every candidate sample.
    let regressions: [String]

    enum CodingKeys: String, CodingKey {
        case id, steward, kind, state, baseline, candidate, regressions
    }
}

/// One point in a metric series.
struct MetricPoint: Codable, Sendable, Equatable {
    let at: String
    let value: Double

    enum CodingKeys: String, CodingKey { case at, value }
}

/// One series of `arya metrics`.
struct MetricSeries: Codable, Sendable, Equatable {
    let metric: String
    let unit: String?
    let target: Double?
    let points: [MetricPoint]

    enum CodingKeys: String, CodingKey { case metric, unit, target, points }
}

/// One row of `arya memory`.
struct MemoryRow: Codable, Sendable, Equatable {
    let id: String
    let text: String
    let tags: [String]
    /// `kind:id` of who wrote it.
    let author: String
    let run: String?
    let retracted: Bool

    enum CodingKeys: String, CodingKey { case id, text, tags, author, run, retracted }
}

/// One row of `arya routines`.
struct RoutineRow: Codable, Sendable, Equatable {
    let name: String
    let language: String
    /// Content hash of the live version, or `nil` when only proposed.
    let liveVersion: String?
    let versions: Int

    enum CodingKeys: String, CodingKey { case name, language, liveVersion, versions }
}

/// One difference between a recorded and a replayed event.
struct Divergence: Codable, Sendable, Equatable {
    let seq: Int
    let type: String
    /// Dotted path of the first differing field.
    let field: String
    let recorded: String
    let replayed: String

    enum CodingKeys: String, CodingKey { case seq, type, field, recorded, replayed }
}

/// The result of `arya replay`.
struct ReplayReport: Codable, Sendable, Equatable {
    let run: String
    /// Derived events compared.
    let events: Int
    let divergences: [Divergence]

    enum CodingKeys: String, CodingKey { case run, events, divergences }
}

/// What the improvement-loop commands need from an arya home.
protocol ImprovementBackend: Sendable {
    func importCasebook(steward: String, path: String, name: String?) async throws(CLIError)
        -> CasebookRow
    func listCasebooks(steward: String?) async throws(CLIError) -> [CasebookRow]
    func rehearse(steward: String, casebook: String?) async throws(CLIError) -> RehearsalReport
    func correct(steward: String, case: String, choice: String?, note: String?)
        async throws(CLIError) -> CorrectionReport
    func markReady(steward: String) async throws(CLIError) -> StewardDetail
    func propose(steward: String, charterPath: String) async throws(CLIError) -> ProposalRow
    func listProposals(steward: String?) async throws(CLIError) -> [ProposalRow]
    func metrics(steward: String, metric: String?) async throws(CLIError) -> [MetricSeries]
    func memory(steward: String, scope: MemoryScope) async throws(CLIError) -> [MemoryRow]
    func routines(steward: String) async throws(CLIError) -> [RoutineRow]
    func replay(run: String) async throws(CLIError) -> ReplayReport
    /// Serves until stdin closes.
    func serveBindingProxy(steward: String, run: String, binding: String, recorded: String?)
        async throws(CLIError)
}

/// Which memory notes a listing includes.
enum MemoryScope: Sendable, Equatable {
    case live
    case all
}
