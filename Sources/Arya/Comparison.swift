import AryaCore
import AryaEval
import Foundation

extension Workspace {
    /// The side-by-side backtest of a gated proposal, from the two rehearsals its gate already
    /// ran (no new runs): current against proposed per case, which improved and regressed, and
    /// metric deltas. `nil` until the proposal has been gated on a baseline.
    public func comparison(proposal id: String) async throws -> BacktestView? {
        let events = try facadeState().runtime
        guard let found = try ProposalBook(events).records[ProposalID(unchecked: id)] else {
            throw WorkspaceError.notFound(id)
        }
        let gated = try events.filter { $0.type == ProposalEventType.gated }
            .map {
                try CanonicalJSON.decode(
                    ProposalGatedPayload.self, from: try CanonicalJSON.encode($0.payload))
            }
            .last { $0.proposal == found.id }
        guard let gated, let baseline = gated.baseline, let candidate = gated.candidate else {
            return nil
        }
        let live = try await existing(found.steward.rawValue)
        let comparison: BacktestComparison
        do {
            comparison = try await Backtests(
                reports: RehearsalReports(sink: readSink, casebooks: casebookSource)
            ).compare(
                current: baseline, proposed: candidate, tolerance: live.charter.gate.tolerance)
        } catch let error as EvalError {
            throw WorkspaceError.rejected(String(describing: error))
        }
        return BacktestView.build(
            comparison, currentLabel: "Live v\(found.baseVersion)",
            proposedLabel: "Proposed v\(found.candidateVersion)", metric: found.charter.metric)
    }
}
