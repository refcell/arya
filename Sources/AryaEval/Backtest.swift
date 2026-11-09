import AryaCore
import AryaRuntime

/// One variant of a steward to backtest: the live charter, a proposed charter, or the live
/// charter with a candidate routine.
public struct BacktestVariant: Hashable, Sendable {
    /// The version the charter is (or would be); 0 for a proposed charter.
    public var charterVersion: Int
    public var charter: Charter
    public var proposal: ProposalID?
    public var routine: RoutineCandidate?

    public init(
        charterVersion: Int, charter: Charter, proposal: ProposalID? = nil,
        routine: RoutineCandidate? = nil
    ) {
        self.charterVersion = charterVersion
        self.charter = charter
        self.proposal = proposal
        self.routine = routine
    }
}

/// How a case fared under the proposed variant compared with the current one.
public enum CaseChange: String, Hashable, Sendable, Codable {
    /// Now passes where it failed, or scores higher.
    case improved
    /// Now fails where it passed, or scores lower.
    case regressed
    case unchanged
}

/// One side of a backtest.
public struct BacktestSide: Hashable, Sendable, Codable {
    public var rehearsal: RehearsalID
    public var charterVersion: Int
    public var proposal: ProposalID?
    public var routine: RoutineCandidate?
    public var meanScore: Double
    /// Cases that passed in every sample.
    public var passed: Int
    public var leaks: Int
}

/// What one variant did on one case.
public struct CaseVariantResult: Hashable, Sendable, Codable {
    public var runs: [RunID?]
    /// The first sample's result; `nil` when its run failed.
    public var actual: JSONValue?
    /// Mean over samples; 0 when leaked.
    public var score: Double
    public var passed: Bool
    public var leak: Bool
    public var notes: [String]
    /// The first sample's differences from `expected`.
    public var diff: [FieldDiff]
    /// What this variant would have done, in words.
    public var text: String
    /// The differences in a line, or `matches expected`.
    public var diffText: String
    /// The first sample's score in a line (`CaseScore.text`).
    public var scoreText: String
}

/// One case side by side: what each variant would have done and what actually happened.
public struct BacktestCase: Hashable, Sendable, Codable {
    public var caseID: CaseID
    public var input: String
    /// What actually happened, as recorded in the casebook and corrected by people.
    public var expected: JSONValue
    /// What actually happened, in words.
    public var expectedText: String
    public var current: CaseVariantResult
    public var proposed: CaseVariantResult
    /// `proposed.score - current.score`.
    public var delta: Double
    public var change: CaseChange
    /// One line for the Improve screen: `case-0006 improved: now chose billing (was how-to)`.
    public var summary: String
}

/// A strategy backtest: two variants rehearsed on the same casebook, compared case by case.
/// `verdict` is the gate rule (decision 0017) with the current side as the baseline.
public struct BacktestComparison: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var casebook: String
    public var casebookVersion: String
    public var current: BacktestSide
    public var proposed: BacktestSide
    public var cases: [BacktestCase]
    public var meanDelta: Double
    public var improved: Int
    public var regressed: Int
    public var verdict: GateCheckVerdict
    /// One line: `proposed: 1 improved, 1 regressed (mean 0.88 to 0.88); gate fails: case
    /// regressed`.
    public var summary: String
}

/// Rehearses two variants on one casebook and compares them.
public struct Backtester: Sendable {
    public var rehearser: any Rehearser
    public var reports: RehearsalReports

    public init(rehearser: any Rehearser, reports: RehearsalReports) {
        self.rehearser = rehearser
        self.reports = reports
    }

    /// Rehearses `current` then `proposed` (`samples` each) and compares them. `tolerance` is
    /// the live charter's gate tolerance.
    public func run(
        steward: StewardID, casebookVersion: String, current: BacktestVariant,
        proposed: BacktestVariant, samples: Int = 1, tolerance: Double = 0
    ) async throws -> BacktestComparison {
        var ids: [RehearsalID] = []
        for variant in [current, proposed] {
            let result = try await rehearser.rehearse(
                RehearsalRequest(
                    steward: steward, charterVersion: variant.charterVersion,
                    casebookVersion: casebookVersion, samples: samples,
                    proposal: variant.proposal, routine: variant.routine),
                charter: variant.charter)
            guard let id = result.id else { throw EvalError.notImplemented("rehearsal without id") }
            ids.append(id)
        }
        return try await Backtests(reports: reports).compare(
            current: ids[0], proposed: ids[1], tolerance: tolerance)
    }
}

/// Builds `BacktestComparison`s from two recorded rehearsals.
public struct Backtests: Sendable {
    public var reports: RehearsalReports

    public init(reports: RehearsalReports) {
        self.reports = reports
    }

    /// Compares two finished rehearsals of the same steward and casebook.
    public func compare(
        current: RehearsalID, proposed: RehearsalID, tolerance: Double = 0
    ) async throws -> BacktestComparison {
        let old = try await reports.report(current)
        let new = try await reports.report(proposed)
        guard old.casebookVersion == new.casebookVersion else {
            throw EvalError.casebookMismatch(
                expected: old.casebookVersion, actual: new.casebookVersion)
        }
        let cases = zip(old.cases, new.cases).map { Self.compare($0, $1) }
        let verdict = GateRule.evaluate(
            baseline: try await reports.result(current),
            candidate: try await reports.result(proposed), tolerance: tolerance)
        return BacktestComparison(
            steward: new.steward, casebook: new.casebook, casebookVersion: new.casebookVersion,
            current: Self.side(old), proposed: Self.side(new), cases: cases,
            meanDelta: new.meanScore - old.meanScore,
            improved: cases.filter { $0.change == .improved }.count,
            regressed: cases.filter { $0.change == .regressed }.count, verdict: verdict,
            summary: Self.summary(cases, old.meanScore, new.meanScore, verdict))
    }

    static func summary(
        _ cases: [BacktestCase], _ old: Double, _ new: Double, _ verdict: GateCheckVerdict
    ) -> String {
        let up = cases.filter { $0.change == .improved }.count
        let down = cases.filter { $0.change == .regressed }.count
        let gate = verdict.passed ? "gate passes" : "gate fails: \(verdict.reason)"
        return "proposed: \(up) improved, \(down) regressed "
            + "(mean \(format(old)) to \(format(new))); \(gate)"
    }

    static func side(_ report: RehearsalReport) -> BacktestSide {
        BacktestSide(
            rehearsal: report.rehearsal, charterVersion: report.charterVersion,
            proposal: report.proposal, routine: report.routine, meanScore: report.meanScore,
            passed: report.passed, leaks: report.leaks)
    }

    static func compare(_ old: CaseReport, _ new: CaseReport) -> BacktestCase {
        let current = variant(old)
        let proposed = variant(new)
        let delta = proposed.score - current.score
        let change: CaseChange
        if proposed.passed != current.passed {
            change = proposed.passed ? .improved : .regressed
        } else if abs(delta) > 1e-9 {
            change = delta > 0 ? .improved : .regressed
        } else {
            change = .unchanged
        }
        return BacktestCase(
            caseID: new.caseID, input: new.input, expected: new.expected,
            expectedText: new.expectedText, current: current, proposed: proposed, delta: delta,
            change: change, summary: summary(new.caseID, change, current, proposed))
    }

    static func variant(_ report: CaseReport) -> CaseVariantResult {
        let scores = report.samples.map(\.score.value)
        let mean = scores.isEmpty || report.leak ? 0 : scores.reduce(0, +) / Double(scores.count)
        let first = report.samples.first
        return CaseVariantResult(
            runs: report.samples.map(\.run), actual: first?.actual, score: mean,
            passed: report.passed && !report.leak, leak: report.leak,
            notes: report.samples.flatMap(\.score.notes), diff: first?.diff ?? [],
            text: first?.text ?? "no result", diffText: first?.diffText ?? "no result",
            scoreText: first?.scoreText ?? "no score")
    }

    static func summary(
        _ id: CaseID, _ change: CaseChange, _ current: CaseVariantResult,
        _ proposed: CaseVariantResult
    ) -> String {
        switch change {
        case .unchanged:
            return "\(id.rawValue) unchanged: \(proposed.passed ? "passes" : "fails") both ways"
        case .improved, .regressed:
            let verb = change == .improved ? "improved" : "regressed"
            guard proposed.text != current.text else {
                return "\(id.rawValue) \(verb): score \(format(current.score)) to "
                    + format(proposed.score)
            }
            return "\(id.rawValue) \(verb): now \(proposed.text) (was \(current.text))"
        }
    }

    static func format(_ value: Double) -> String {
        ResultText.value(.double((value * 100).rounded() / 100))
    }
}
