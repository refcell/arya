import AryaCore
import AryaEval
import Foundation

/// The backtest-before-live gate for a charter proposal, for the Improve screen.
public struct LiveReadinessSummary: Sendable, Hashable, Codable {
    public var proposal: String
    public var steward: String
    public var ready: Bool
    /// One sentence, shown verbatim, for example
    /// `Not ready: case-0005 would regress; 2 of last 20 runs would change`
    public var summary: String
    /// One line per regression, shown verbatim.
    public var regressions: [String]
    /// Casebook cases that would improve.
    public var improved: [String]
    /// Recent live runs checked.
    public var runsChecked: Int
    /// The fresh casebook backtest, side by side.
    public var comparison: BacktestView
}

extension Workspace {
    /// Backtests a proposal against the live charter on the steward's newest casebook (two
    /// fresh rehearsals) and replays its last `recent` finished live runs under the proposed
    /// charter as rehearsal-mode cases. Nothing executes; the what-if runs never count as
    /// rehearsals.
    public func liveReadiness(proposal id: String, recent: Int = 20) async throws
        -> LiveReadinessSummary
    {
        guard
            let found = try facadeState().proposals
                .records[ProposalID(unchecked: id)]
        else { throw WorkspaceError.notFound(id) }
        let live = try await existing(found.steward.rawValue)
        let book = try await casebook(for: found.steward.rawValue, version: nil)
        let runner = RuntimeCaseRunner(loop: engine, sink: sink)
        let gate = LiveReadinessGate(
            backtester: Backtester(
                rehearser: rehearser,
                reports: RehearsalReports(sink: readSink, casebooks: casebookSource)),
            counterfactuals: Counterfactuals(sink: sink, runner: runner, ambient: ambient))
        let result: LiveReadiness
        do {
            result = try await gate.check(
                steward: found.steward, casebookVersion: book.version,
                current: BacktestVariant(charterVersion: live.version, charter: live.charter),
                proposed: BacktestVariant(
                    charterVersion: 0, charter: found.charter, proposal: found.id),
                recent: recent, tolerance: live.charter.gate.tolerance)
        } catch let error as EvalError {
            throw WorkspaceError.rejected(String(describing: error))
        }
        return LiveReadinessSummary(
            proposal: id, steward: found.steward.rawValue, ready: result.ready,
            summary: result.summary, regressions: result.regressionLines,
            improved: result.casebook.cases.filter { $0.change == .improved }
                .map(\.caseID.rawValue),
            runsChecked: result.runs.count,
            comparison: BacktestView.build(
                result.casebook, currentLabel: "Live v\(live.version)",
                proposedLabel: "Proposed v\(found.candidateVersion)",
                metric: found.charter.metric))
    }
}
