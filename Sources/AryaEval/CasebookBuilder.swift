import AryaCore
import AryaLedger
import AryaRuntime

/// Why a live run became a case.
public enum HarvestReason: String, Hashable, Sendable, Codable {
    /// A person corrected the run; the case expects the correction.
    case corrected
    /// A person denied one of its actions; the case expects the run without that action.
    case denied
}

/// One live run harvested into a case, with provenance.
public struct HarvestedCase: Hashable, Sendable, Codable {
    public var run: RunID
    public var reason: HarvestReason
    /// The `case.corrected` or `approval.denied` event the case comes from.
    public var event: EventID
    /// Who corrected or denied.
    public var actor: String
    public var caseID: CaseID
}

/// The result of growing a casebook from history.
public struct HarvestOutcome: Sendable {
    /// The new casebook, recorded as a version; `nil` when nothing new was found.
    public var casebook: Casebook?
    public var harvested: [HarvestedCase]
}

/// Grows a casebook from real history: every live run of the steward that a person corrected
/// or whose action a person denied becomes a case (`run-<run id>`), unless the casebook already
/// has it. Corrections win over denials; the latest correction wins. A denied action is
/// dropped from the expected actions. Each case's `source` names its run, reason and event.
public struct CasebookBuilder: Sendable {
    public var sink: any EventSink
    public var blobs: any EvalBlobStore

    public init(sink: any EventSink, blobs: any EvalBlobStore) {
        self.sink = sink
        self.blobs = blobs
    }

    /// Finds the candidates without recording anything.
    public func candidates(steward: StewardID, in book: Casebook) async throws
        -> [(Case, HarvestedCase)]
    {
        let events = try await sink.events(from: 1)
        let known = Set(book.cases.map(\.id))
        var found: [RunID: (Case, HarvestedCase)] = [:]
        for event in events where event.draft.steward == steward {
            guard let (run, expected, reason) = try Self.signal(event, events) else { continue }
            guard try Self.isLive(events, run) else { continue }
            if found[run]?.1.reason == .corrected, reason == .denied { continue }
            let caseID = try RunCases.caseID(for: run)
            guard !known.contains(caseID) else { continue }
            var item = try RunCases.makeCase(events, run: run, expected: expected(events, run))
            let provenance = HarvestedCase(
                run: run, reason: reason, event: event.id,
                actor: "\(event.draft.actor.kind):\(event.draft.actor.id)", caseID: caseID)
            item.source =
                "run \(run.rawValue) \(reason.rawValue) by \(provenance.actor) "
                + "(event \(event.id.rawValue))"
            found[run] = (item, provenance)
        }
        return found.values.sorted { $0.1.caseID < $1.1.caseID }
    }

    /// Adds the candidates to `book` and records the new version as a correction of `book`.
    public func harvest(steward: StewardID, into book: Casebook, actor: RuntimeActor = .system)
        async throws -> HarvestOutcome
    {
        let found = try await candidates(steward: steward, in: book)
        guard !found.isEmpty else { return HarvestOutcome(casebook: nil, harvested: []) }
        var next = book
        for (item, _) in found { next = try next.upserting(item) }
        try await CasebookImporter(blobs: blobs, sink: sink).record(
            next, steward: steward, actor: actor, correctedFrom: book.version)
        return HarvestOutcome(casebook: next, harvested: found.map(\.1))
    }

    typealias Expectation = @Sendable ([RuntimeEvent], RunID) throws -> JSONValue

    /// A correction or denial event: its run, how to compute the expected result, and why.
    static func signal(_ event: RuntimeEvent, _ events: [RuntimeEvent]) throws
        -> (RunID, Expectation, HarvestReason)?
    {
        switch event.type {
        case EvalEventType.caseCorrected:
            let body = try EvalPayload.decode(CaseCorrectedPayload.self, event.payload)
            guard let run = body.run, let expected = body.expected else { return nil }
            return (run, { _, _ in expected }, .corrected)
        case ApprovalEventType.denied:
            let body = try EvalPayload.decode(ApprovalDenied.self, event.payload)
            guard let (run, action) = try requested(body.approval, events) else { return nil }
            return (
                run,
                { events, run in
                    var did = try RunCases.did(events, run: run).objectValue ?? [:]
                    let actions = did["actions"]?.arrayValue ?? []
                    did["actions"] = .array(actions.filter { !Self.same($0, action) })
                    return .object(did)
                }, .denied
            )
        default:
            return nil
        }
    }

    /// The run and action of an action approval.
    static func requested(_ approval: ApprovalID, _ events: [RuntimeEvent]) throws
        -> (RunID, ProposedAction)?
    {
        for event in events where event.type == ApprovalEventType.requested {
            let body = try EvalPayload.decode(ApprovalRequested.self, event.payload)
            if body.approval == approval, let action = body.action, let run = event.draft.run {
                return (run, action)
            }
        }
        return nil
    }

    static func same(_ value: JSONValue, _ action: ProposedAction) -> Bool {
        value["kind"]?.stringValue == action.kind && value["target"]?.stringValue == action.target
    }

    /// Live runs only: rehearsal runs already come from a case.
    static func isLive(_ events: [RuntimeEvent], _ run: RunID) throws -> Bool {
        guard
            let started = events.first(where: {
                $0.draft.run == run && $0.type == RunEventType.started
            })
        else { return false }
        return try EvalPayload.decode(RunStarted.self, started.payload).rehearsal == nil
    }
}
