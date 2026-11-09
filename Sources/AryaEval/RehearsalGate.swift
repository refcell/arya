import AryaCore
import AryaRuntime

/// The eval gate (decision 0017). It rehearses the proposal's candidate on the casebook,
/// rehearsing the live charter first when no baseline exists, applies `GateRule`, and records
/// `proposal.gated`. Both sides are scored with the live charter's scorer and gated with the
/// live charter's `gate` settings, so a proposal cannot loosen its own gate.
public struct RehearsalGate: Gate {
    public var sink: any EventSink
    public var rehearser: any Rehearser

    public init(sink: any EventSink, rehearser: any Rehearser) {
        self.sink = sink
        self.rehearser = rehearser
    }

    public func check(_ request: GateCheckRequest) async throws -> GateCheckVerdict {
        let events = try await sink.events(from: 1)
        guard let live = try StewardBook(events).records[request.steward] else {
            throw StewardError.notFound(request.steward)
        }
        guard let proposal = try ProposalBook(events).records[request.proposal] else {
            throw ProposalError.notFound(request.proposal)
        }
        guard proposal.steward == request.steward else {
            throw ProposalError.stewardMismatch(expected: request.steward, got: proposal.steward)
        }
        let config = live.charter.gate
        var baseline = try RehearsalBook(events).baseline(
            steward: live.id, charterVersion: live.version,
            casebookVersion: request.casebookVersion)
        if baseline == nil {
            baseline = try await rehearser.rehearse(
                RehearsalRequest(
                    steward: live.id, charterVersion: live.version,
                    casebookVersion: request.casebookVersion, samples: config.samples),
                charter: live.charter)
        }
        var candidateCharter = proposal.charter
        candidateCharter.scorer = live.charter.scorer
        candidateCharter.gate = config
        let candidate = try await rehearser.rehearse(
            RehearsalRequest(
                steward: live.id, charterVersion: proposal.candidateVersion,
                casebookVersion: request.casebookVersion, samples: config.samples,
                proposal: proposal.id),
            charter: candidateCharter)
        let verdict = GateRule.evaluate(
            baseline: baseline, candidate: candidate, tolerance: config.tolerance)
        let payload = ProposalGatedPayload(
            proposal: proposal.id, casebook: request.casebookVersion, baseline: baseline?.id,
            candidate: candidate.id, verdict: verdict)
        _ = try await sink.append(
            RuntimeEventDraft(
                type: ProposalEventType.gated, steward: live.id, actor: .system,
                payload: try CanonicalJSON.jsonValue(payload)))
        return verdict
    }
}
