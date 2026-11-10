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
    /// One sentence, shown verbatim (`ReadinessCounts.sentence`): `Ready: casebook 8/8, none of
    /// last 20 runs would change` or `Not ready: case-0005 would regress; 2 of last 20 runs would
    /// change`.
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
        let counts = ReadinessCounts(
            passed: casebook.proposed.passed, total: casebook.cases.count,
            gatePassed: casebook.verdict.passed, gateReason: casebook.verdict.reason,
            regressedCases: cases.map(\.caseID.rawValue), checked: runs.count,
            changed: runs.filter { $0.verdict == .regressed }.count,
            failed: runs.filter { $0.verdict == .failed }.count,
            improved: runs.filter { $0.verdict == .improved }.count)
        return LiveReadiness(
            steward: steward, proposal: proposal, casebook: casebook, runs: runs,
            regressions: cases.map(\.caseID.rawValue) + bad.map { "run \($0.run.rawValue)" },
            regressionLines: cases.map { "\($0.caseID.rawValue): \($0.proposed.diffText)" }
                + bad.map { "run \($0.run.rawValue): \($0.whatIf.summary)" },
            ready: counts.ready, summary: counts.sentence)
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

    /// The steward's latest finished top-level live runs, newest first; a crew is its parent.
    static func recentRuns(_ events: [RuntimeEvent], steward: StewardID, limit: Int) throws
        -> [RunID]
    {
        var live: Set<RunID> = []
        var finished: [RunID] = []
        for event in events where event.draft.steward == steward {
            guard let run = event.draft.run else { continue }
            if event.type == RunEventType.started {
                // A crew counts once, as its parent: children and join runs are not items.
                let body = try EvalPayload.decode(RunStarted.self, event.payload)
                if body.rehearsal == nil, !CrewTree.isMember(body) { live.insert(run) }
            } else if event.type == RunEventType.finished, live.contains(run) {
                finished.append(run)
            }
        }
        return Array(finished.reversed().prefix(max(0, limit)))
    }
}

/// What the live-readiness sentence says, as counts.
public struct ReadinessCounts: Hashable, Sendable {
    /// Casebook cases the proposed charter passes, of `total`.
    public var passed: Int
    public var total: Int
    public var gatePassed: Bool
    /// The casebook gate's reason when it failed, for example `mean below baseline`.
    public var gateReason: String
    public var regressedCases: [String]
    /// Recent live runs checked, and how many would change, fail, or improve.
    public var checked: Int
    public var changed: Int
    public var failed: Int
    public var improved: Int

    public init(
        passed: Int, total: Int, gatePassed: Bool, gateReason: String = "",
        regressedCases: [String] = [], checked: Int, changed: Int = 0, failed: Int = 0,
        improved: Int = 0
    ) {
        self.passed = passed
        self.total = total
        self.gatePassed = gatePassed
        self.gateReason = gateReason
        self.regressedCases = regressedCases
        self.checked = checked
        self.changed = changed
        self.failed = failed
        self.improved = improved
    }

    public var ready: Bool { gatePassed && changed == 0 && failed == 0 }

    /// One sentence for the Improve screen, shown verbatim. Ready:
    /// `Ready: casebook 8/8, none of last 20 runs would change` (or `2 of last 20 runs would
    /// improve`, `the last run would not change`, `no recent runs to check`). Not ready, in this
    /// order: `case-0005 would regress` (at most three ids, then `and N more`), `casebook gate
    /// failed: <reason>` when no case regressed, `2 of last 20 runs would change`, and
    /// `1 of last 20 runs would fail`, joined with `; `.
    public var sentence: String {
        if ready { return "Ready: casebook \(passed)/\(total), " + readyRuns }
        var parts: [String] = []
        if !regressedCases.isEmpty {
            parts.append(Self.list(regressedCases) + " would regress")
        } else if !gatePassed {
            parts.append(
                gateReason.isEmpty ? "casebook gate failed" : "casebook gate failed: \(gateReason)")
        }
        if changed > 0 { parts.append(count(changed, "change")) }
        if failed > 0 { parts.append(count(failed, "fail")) }
        return "Not ready: " + parts.joined(separator: "; ")
    }

    var readyRuns: String {
        if checked == 0 { return "no recent runs to check" }
        if improved > 0 { return count(improved, "improve") }
        return checked == 1
            ? "the last run would not change" : "none of last \(checked) runs would change"
    }

    func count(_ some: Int, _ verb: String) -> String {
        checked == 1
            ? "the last run would \(verb)" : "\(some) of last \(checked) runs would \(verb)"
    }

    /// `a`, `a and b`, `a, b and c`, `a, b, c and 2 more`.
    static func list(_ ids: [String]) -> String {
        if ids.count > 3 {
            return ids.prefix(3).joined(separator: ", ") + " and \(ids.count - 3) more"
        }
        if ids.count == 1 { return ids[0] }
        return ids.dropLast().joined(separator: ", ") + " and " + ids[ids.count - 1]
    }
}
