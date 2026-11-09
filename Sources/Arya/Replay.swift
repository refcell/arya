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

/// What a run would have done under another charter, for the run thread.
public struct WhatIfSummary: Sendable, Hashable, Codable {
    public var run: String
    public var steward: String
    /// The proposal whose charter answered, or `nil` for the live charter.
    public var proposal: String?
    /// The rehearsal-mode run that answered; `nil` when it could not start.
    public var rehearsalRun: String?
    /// What the run did and what it would have done, in words.
    public var did: String
    public var wouldHave: String
    /// Paths where the two differ, for example `decisions[0].choice`.
    public var differences: [String]
    /// Whether it would now match the person's correction; `nil` without one.
    public var fixesCorrection: Bool?
    public var leak: Bool
    /// One line for the run thread, shown verbatim.
    public var summary: String
}

extension Workspace {
    /// Runs `run` again as a rehearsal-mode case under a proposal's charter (or the steward's
    /// live charter) and says what it would have done. Never counts as a rehearsal, and its
    /// actions are never executed.
    public func whatIf(run: String, proposal: String? = nil) async throws -> WhatIfSummary {
        guard let record = try await runBook().records[RunID(unchecked: run)] else {
            throw WorkspaceError.notFound(run)
        }
        let charter: Charter
        var proposalID: ProposalID?
        if let proposal {
            guard
                let found = try ProposalBook(try await sink.events(from: 1))
                    .records[ProposalID(unchecked: proposal)],
                found.steward == record.steward
            else { throw WorkspaceError.notFound(proposal) }
            charter = found.charter
            proposalID = found.id
        } else {
            charter = try await existing(record.steward.rawValue).charter
        }
        let answer: RunCounterfactual
        do {
            answer = try await Counterfactuals(
                sink: sink, runner: RuntimeCaseRunner(loop: engine, sink: sink), ambient: ambient
            ).whatIf(run: record.id, charter: charter, proposal: proposalID)
        } catch EvalError.unknownRun {
            throw WorkspaceError.notFound(run)
        } catch let error as EvalError {
            throw WorkspaceError.rejected(String(describing: error))
        }
        return WhatIfSummary(
            run: run, steward: record.steward.rawValue, proposal: proposal,
            rehearsalRun: answer.rehearsalRun?.rawValue, did: answer.didText,
            wouldHave: answer.wouldHaveText, differences: answer.diff.map(\.path),
            fixesCorrection: answer.fixesCorrection, leak: answer.leak, summary: answer.summary)
    }
}
