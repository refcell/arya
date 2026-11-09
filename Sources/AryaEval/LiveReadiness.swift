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
    public var ready: Bool
    /// One line, shown verbatim: `ready: casebook 8/8, 20 recent runs unchanged` or
    /// `not ready: case-0005 regressed; run run_… regressed`.
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
        let caseRegressions = casebook.cases.filter { $0.change == .regressed }.map(
            \.caseID.rawValue)
        let runRegressions = runs.filter { $0.verdict == .regressed || $0.verdict == .failed }
            .map { "run \($0.run.rawValue)" }
        let regressions = caseRegressions + runRegressions
        let ready = casebook.verdict.passed && runRegressions.isEmpty
        let summary: String
        if ready {
            let improved = runs.filter { $0.verdict == .improved }.count
            summary =
                "ready: casebook \(casebook.proposed.passed)/\(casebook.cases.count), "
                + "\(runs.count) recent runs checked"
                + (improved > 0 ? ", \(improved) improved" : ", none changed")
        } else if regressions.isEmpty {
            summary = "not ready: \(casebook.verdict.reason)"
        } else {
            summary = "not ready: " + regressions.joined(separator: ", ") + " regressed"
        }
        return LiveReadiness(
            steward: steward, proposal: proposal, casebook: casebook, runs: runs,
            regressions: regressions, ready: ready, summary: summary)
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
