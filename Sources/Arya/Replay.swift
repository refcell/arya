import AryaCore
import AryaEval
import Foundation

/// The result of replaying a run.
public struct ReplaySummary: Sendable, Hashable, Codable {
    /// Where a replay first differed from the recording.
    public struct Difference: Sendable, Hashable, Codable {
        /// Position among the run's events, from 0.
        public var index: Int
        /// Ledger `seq` of the recorded event, when there is one.
        public var seq: Int?
        /// Event type (recorded, else replayed).
        public var type: String
        /// Dotted path of the first differing field, for example `payload.status`.
        public var field: String
        /// Recorded and replayed events as canonical JSON (`{"type","payload"}`), or empty.
        public var recorded: String
        public var replayed: String
    }

    /// Run id.
    public var run: String
    /// Events compared (the longer of the two sequences).
    public var events: Int
    /// The first difference; empty when the replay matched the recording exactly.
    public var divergences: [Difference]
}

extension Workspace {
    /// Replays a run from the ledger alone through `AryaEval.RunReplayer` (recorded adapter
    /// conversation and executor outputs, a scratch sink) and reports the first difference
    /// from the recording. Nothing is written to the home.
    public func replay(run id: String) async throws -> ReplaySummary {
        let report: ReplayReport
        do {
            report = try await RunReplayer(sink: sink, casebooks: casebookSource)
                .replay(run: RunID(unchecked: id))
        } catch EvalError.unknownRun(let run) {
            throw WorkspaceError.notFound(run.rawValue)
        } catch EvalError.unknownRehearsal(let rehearsal) {
            throw WorkspaceError.notFound(rehearsal.rawValue)
        } catch EvalError.unknownCase(let caseID) {
            throw WorkspaceError.notFound(caseID.rawValue)
        }
        return ReplaySummary(
            run: id, events: report.comparedEvents,
            divergences: try report.divergence.map { [try ReplaySummary.Difference($0)] } ?? [])
    }
}

extension ReplaySummary.Difference {
    init(_ divergence: Divergence) throws {
        func text(_ event: ReplayEvent?) throws -> String {
            guard let event else { return "" }
            return try CanonicalJSON.string(
                JSONValue.object(["type": .string(event.type), "payload": event.payload]))
        }
        self.init(
            index: divergence.index, seq: divergence.recorded?.seq,
            type: divergence.recorded?.type ?? divergence.replayed?.type ?? "",
            field: divergence.path, recorded: try text(divergence.recorded),
            replayed: try text(divergence.replayed))
    }
}
