import AryaCore
import AryaMemory
import AryaRuntime

/// The eval gate for charter proposals (decisions 0017 and 0027). It rehearses the proposal's
/// candidate on the casebook, rehearsing the live charter first when no fresh baseline exists,
/// applies `GateRule`, and records `proposal.gated`. Both sides are scored with the live
/// charter's scorer and gated with the live charter's `gate` settings, so a proposal cannot
/// loosen its own gate.
public struct RehearsalGate: Gate {
    public var sink: any EventSink
    public var rehearser: any Rehearser

    public init(sink: any EventSink, rehearser: any Rehearser) {
        self.sink = sink
        self.rehearser = rehearser
    }

    public func check(_ request: GateCheckRequest) async throws -> GateCheckVerdict {
        let events = try await sink.events(from: 1)
        guard let proposal = try ProposalBook(events).records[request.proposal] else {
            throw ProposalError.notFound(request.proposal)
        }
        guard proposal.steward == request.steward else {
            throw ProposalError.stewardMismatch(expected: request.steward, got: proposal.steward)
        }
        let flow = GateFlow(sink: sink, rehearser: rehearser)
        let live = try flow.live(request.steward, events)
        var candidate = proposal.charter
        candidate.scorer = live.charter.scorer
        candidate.gate = live.charter.gate
        return try await flow.run(
            live: live, events: events, casebookVersion: request.casebookVersion,
            candidate: RehearsalRequest(
                steward: live.id, charterVersion: proposal.candidateVersion,
                casebookVersion: request.casebookVersion, samples: live.charter.gate.samples,
                proposal: proposal.id),
            charter: candidate)
    }
}

/// The eval gate for routine proposals (decision 0025): rehearses the live charter with the
/// candidate routine in place of the live version of its name, against the same baseline and
/// rule as charter gates, and records `proposal.gated` with the routine.
public struct RoutineRehearsalGate: RoutineGateChecking {
    public var sink: any EventSink
    public var rehearser: any Rehearser

    public init(sink: any EventSink, rehearser: any Rehearser) {
        self.sink = sink
        self.rehearser = rehearser
    }

    public func check(_ request: RoutineGateRequest) async throws -> GateCheckVerdict {
        let events = try await sink.events(from: 1)
        let flow = GateFlow(sink: sink, rehearser: rehearser)
        let live = try flow.live(request.steward, events)
        return try await flow.run(
            live: live, events: events, casebookVersion: request.casebookVersion,
            candidate: RehearsalRequest(
                steward: live.id, charterVersion: live.version,
                casebookVersion: request.casebookVersion, samples: live.charter.gate.samples,
                proposal: request.proposal,
                routine: RoutineCandidate(name: request.name, version: request.candidateVersion)),
            charter: live.charter)
    }
}

/// The steps both gates share.
struct GateFlow: Sendable {
    var sink: any EventSink
    var rehearser: any Rehearser

    /// Event types that change what a steward's runs see; a baseline must be newer.
    static let configurationTypes: Set<String> = [
        StewardEventType.created, StewardEventType.charterUpdated, RoutineEventType.promoted,
    ]

    func live(_ steward: StewardID, _ events: [RuntimeEvent]) throws -> StewardRecord {
        guard let live = try StewardBook(events).records[steward] else {
            throw StewardError.notFound(steward)
        }
        return live
    }

    func run(
        live: StewardRecord, events: [RuntimeEvent], casebookVersion: String,
        candidate request: RehearsalRequest, charter: Charter
    ) async throws -> GateCheckVerdict {
        let changed =
            events.last {
                $0.draft.steward == live.id && Self.configurationTypes.contains($0.type)
            }?.seq ?? 0
        var baseline = try RehearsalBook(events).baseline(
            steward: live.id, charterVersion: live.version, casebookVersion: casebookVersion,
            after: changed)
        if baseline == nil {
            baseline = try await rehearser.rehearse(
                RehearsalRequest(
                    steward: live.id, charterVersion: live.version,
                    casebookVersion: casebookVersion, samples: live.charter.gate.samples),
                charter: live.charter)
        }
        let candidate = try await rehearser.rehearse(request, charter: charter)
        let verdict = GateRule.evaluate(
            baseline: baseline, candidate: candidate, tolerance: live.charter.gate.tolerance)
        if let proposal = request.proposal {
            let payload = ProposalGatedPayload(
                proposal: proposal, casebook: casebookVersion, baseline: baseline?.id,
                candidate: candidate.id, routine: request.routine, verdict: verdict)
            _ = try await sink.append(
                RuntimeEventDraft(
                    type: ProposalEventType.gated, steward: live.id, actor: .system,
                    payload: try CanonicalJSON.jsonValue(payload)))
        }
        return verdict
    }
}
