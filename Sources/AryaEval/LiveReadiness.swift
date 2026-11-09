import AryaCore
import AryaLedger
import AryaRuntime

/// How a proposed change would treat one recent live run.
public enum RunVerdict: String, Hashable, Sendable, Codable {
    /// Same as what the run did, or what a person corrected it to.
    case same
    /// Now matches a correction the run missed.
    case improved
    /// Changes a run nobody objected to.
    case regressed
    /// Still misses the run's correction.
    case stillWrong
    /// The rehearsal-mode run failed or leaked.
    case failed
}

/// One recent live run under the proposed change.
public struct RunCheck: Hashable, Sendable, Codable {
    public var run: RunID
    public var verdict: RunVerdict
    public var whatIf: RunCounterfactual
}

/// The backtest-before-live gate: a proposed change against the casebook and the steward's
/// last real runs, as one verdict.
public struct LiveReadiness: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var proposal: ProposalID?
    public var casebook: BacktestComparison
    public var runs: [RunCheck]
    /// Regressed casebook cases (`case-0005`) then regressed or failed runs (`run run_01…`).
    public var regressions: [String]
    /// One line per regression, shown verbatim: `case-0005: decisions[0].choice: expected
    /// security, got account` or `run run_…: with the change it would have: …`.
    public var regressionLines: [String]
    public var ready: Bool
    /// One sentence, shown verbatim: `Ready: casebook 8/8, none of the last 20 runs would
    /// change` or `Not ready: case-0005 would regress; 2 of last 20 runs would change`.
    public var summary: String
}

/// Runs the live-readiness gate.
public struct LiveReadinessGate: Sendable {
    public var backtester: Backtester
    public var counterfactuals: Counterfactuals

    public init(backtester: Backtester, counterfactuals: Counterfactuals) {
        self.backtester = backtester
        self.counterfactuals = counterfactuals
    }

    /// `recent` is how many of the steward's latest finished live runs to replay.
    public func check(
        steward: StewardID, casebookVersion: String, current: BacktestVariant,
        proposed: BacktestVariant, recent: Int = 20, tolerance: Double = 0
    ) async throws -> LiveReadiness {
        let casebook = try await backtester.run(
            steward: steward, casebookVersion: casebookVersion, current: current,
            proposed: proposed, tolerance: tolerance)
        let events = try await counterfactuals.sink.events(from: 1)
        var runs: [RunCheck] = []
        for run in try Self.recentRuns(events, steward: steward, limit: recent) {
            let whatIf = try await counterfactuals.whatIf(
                run: run, charter: proposed.charter, proposal: proposed.proposal)
            runs.append(RunCheck(run: run, verdict: Self.verdict(whatIf), whatIf: whatIf))
        }
        return Self.combine(steward, proposed.proposal, casebook, runs)
    }

    static func combine(
        _ steward: StewardID, _ proposal: ProposalID?, _ casebook: BacktestComparison,
        _ runs: [RunCheck]
    ) -> LiveReadiness {
        let cases = casebook.cases.filter { $0.change == .regressed }
        let bad = runs.filter { $0.verdict == .regressed || $0.verdict == .failed }
        let ready = casebook.verdict.passed && bad.isEmpty
        return LiveReadiness(
            steward: steward, proposal: proposal, casebook: casebook, runs: runs,
            regressions: cases.map(\.caseID.rawValue) + bad.map { "run \($0.run.rawValue)" },
            regressionLines: cases.map { "\($0.caseID.rawValue): \($0.proposed.diffText)" }
                + bad.map { "run \($0.run.rawValue): \($0.whatIf.summary)" },
            ready: ready, summary: sentence(ready, casebook, cases, bad, runs))
    }

    static func sentence(
        _ ready: Bool, _ casebook: BacktestComparison, _ cases: [BacktestCase],
        _ bad: [RunCheck], _ runs: [RunCheck]
    ) -> String {
        let last = "of last \(runs.count) runs"
        let improved = runs.filter { $0.verdict == .improved }.count
        if ready {
            let change =
                improved > 0 ? "\(improved) \(last) would improve" : "none \(last) would change"
            return "Ready: casebook \(casebook.proposed.passed)/\(casebook.cases.count), \(change)"
        }
        var parts: [String] = []
        if !cases.isEmpty {
            let ids = cases.map(\.caseID.rawValue)
            parts.append(ids.joined(separator: ", ") + " would regress")
        }
        if !bad.isEmpty { parts.append("\(bad.count) \(last) would change") }
        if parts.isEmpty { parts.append(casebook.verdict.reason) }
        return "Not ready: " + parts.joined(separator: "; ")
    }

    static func verdict(_ whatIf: RunCounterfactual) -> RunVerdict {
        guard whatIf.wouldHave != nil, !whatIf.leak else { return .failed }
        if let fixes = whatIf.fixesCorrection {
            let wasRight =
                whatIf.corrected.map {
                    ResultDiff.diff(expected: $0, actual: whatIf.did).isEmpty
                } ?? false
            if fixes { return wasRight ? .same : .improved }
            return .stillWrong
        }
        return whatIf.diff.isEmpty ? .same : .regressed
    }

    /// The steward's latest finished live runs, newest first.
    static func recentRuns(_ events: [RuntimeEvent], steward: StewardID, limit: Int) throws
        -> [RunID]
    {
        var live: Set<RunID> = []
        var finished: [RunID] = []
        for event in events where event.draft.steward == steward {
            guard let run = event.draft.run else { continue }
            if event.type == RunEventType.started,
                try EvalPayload.decode(RunStarted.self, event.payload).rehearsal == nil
            {
                live.insert(run)
            } else if event.type == RunEventType.finished, live.contains(run) {
                finished.append(run)
            }
        }
        return Array(finished.reversed().prefix(max(0, limit)))
    }
}
