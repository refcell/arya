import AryaCore
import AryaRuntime

/// What one live run would have done under another charter: the run thread's "with the change
/// it would have…".
public struct RunCounterfactual: Hashable, Sendable, Codable {
    public var run: RunID
    public var steward: StewardID
    public var proposal: ProposalID?
    /// The rehearsal-mode run that answered the question; `nil` when it could not start.
    public var rehearsalRun: RunID?
    /// What the live run did (decision choices, proposed action kinds and targets).
    public var did: JSONValue
    public var didText: String
    /// What it would have done; `nil` when the rehearsal-mode run failed.
    public var wouldHave: JSONValue?
    public var wouldHaveText: String
    /// Where `wouldHave` differs from `did`, compared on the fields `did` states.
    public var diff: [FieldDiff]
    /// The latest correction of this run, when a person corrected it.
    public var corrected: JSONValue?
    /// Whether `wouldHave` matches the correction; `nil` without one.
    public var fixesCorrection: Bool?
    /// The rehearsal-mode run read outside its recorded tool results.
    public var leak: Bool
    /// One line for the run thread, shown verbatim.
    public var summary: String
}

/// Answers "what would this run have done under that charter" by running the run as a case in
/// rehearsal mode: tools are served from the run's recorded results and nothing is executed.
public struct Counterfactuals: Sendable {
    public var sink: any EventSink
    public var runner: any CaseRunner
    public var ambient: Ambient

    public init(sink: any EventSink, runner: any CaseRunner, ambient: Ambient) {
        self.sink = sink
        self.runner = runner
        self.ambient = ambient
    }

    /// `charter` is the proposed charter (a proposal's, when `proposal` is set). The question is
    /// asked under a fresh rehearsal id with no `rehearsal.*` events, so it never counts as a
    /// rehearsal or a baseline.
    public func whatIf(
        run: RunID, charter: Charter, proposal: ProposalID? = nil
    ) async throws -> RunCounterfactual {
        let events = try await sink.events(from: 1)
        var item = try RunCases.makeCase(events, run: run)
        // A crew is asked about as one unit: the whole tree's effect and every member's reads.
        let tree = try CrewTree.members(events, of: run)
        if tree.count > 1 {
            item.expected = try CrewTree.did(events, runs: tree)
            item.context.toolResults = try CrewTree.recordings(events, runs: tree)
        }
        guard let steward = events.first(where: { $0.draft.run == run })?.draft.steward else {
            throw EvalError.unknownRun(run)
        }
        let request = CaseRunRequest(
            steward: steward, charterVersion: 0, charter: charter,
            rehearsal: ambient.newID(RehearsalID.self), caseItem: item, sample: 0)
        var outcome: CaseRunOutcome?
        var failure: String?
        do {
            outcome = try await runner.run(request)
        } catch {
            failure = String(describing: error)
        }
        if tree.count > 1, let answered = outcome?.run {
            let after = try await sink.events(from: 1)
            let replayed = try CrewTree.members(after, of: answered)
            outcome?.result = try CrewTree.did(after, runs: replayed)
        }
        let corrected = try Self.correction(events, run)
        return Self.build(
            run: run, steward: steward, proposal: proposal, did: item.expected,
            outcome: outcome, failure: failure, corrected: corrected)
    }

    static func build(
        run: RunID, steward: StewardID, proposal: ProposalID?, did: JSONValue,
        outcome: CaseRunOutcome?, failure: String?, corrected: JSONValue?
    ) -> RunCounterfactual {
        let would = outcome?.result
        let diff = would.map { ResultDiff.diff(expected: did, actual: $0) } ?? []
        let fixes = corrected.flatMap { want in
            would.map { ResultDiff.diff(expected: want, actual: $0).isEmpty }
        }
        let didText = ResultText.describe(did)
        let wouldText = would.map(ResultText.describe) ?? "no result"
        let summary: String
        if would == nil {
            summary = "with the change it could not run: \(failure ?? "no result")"
        } else if diff.isEmpty {
            summary = "with the change it would have done the same: \(didText)"
        } else {
            summary = "with the change it would have: \(wouldText) (did: \(didText))"
        }
        return RunCounterfactual(
            run: run, steward: steward, proposal: proposal, rehearsalRun: outcome?.run, did: did,
            didText: didText, wouldHave: would, wouldHaveText: wouldText, diff: diff,
            corrected: corrected, fixesCorrection: fixes, leak: outcome?.leak ?? false,
            summary: summary + (fixes == true ? ", which fixes the correction" : ""))
    }

    static func correction(_ events: [RuntimeEvent], _ run: RunID) throws -> JSONValue? {
        var latest: JSONValue?
        for event in events where event.type == EvalEventType.caseCorrected {
            let body = try EvalPayload.decode(CaseCorrectedPayload.self, event.payload)
            if body.run == run, let expected = body.expected { latest = expected }
        }
        return latest
    }
}
