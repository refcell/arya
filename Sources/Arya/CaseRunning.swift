import AryaAdapters
import AryaCore
import AryaEval
import AryaRuntime

/// Runs one rehearsal case through the runtime's run loop (decision 0015).
///
/// The runtime cannot import eval, so the facade bridges them: each case becomes one run with
/// trigger kind `case`, its tool reads answered from `context.toolResults`, and its actions
/// recorded but never executed. The scored result is the run's `run/result` encoded as JSON,
/// which has the shape of a case's `expected` (`decisions`, `actions`, ...).
struct RuntimeCaseRunner: CaseRunner {
    let loop: RunEngine
    let sink: any EventSink

    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let item = request.caseItem
        let input = RunInput(
            kind: .case, text: item.input.text, attachments: item.input.attachments)
        var runRequest = RunRequest(
            steward: request.steward, input: input, mode: .rehearsal(item.context),
            actor: .system, charter: try await candidate(request))
        runRequest.rehearsal = RehearsalTag(
            rehearsal: request.rehearsal, caseID: item.id, sample: request.sample + 1)
        runRequest.routine = request.routine.map {
            CandidateRoutine(name: $0.name, version: $0.version)
        }
        let outcome = try await loop.run(runRequest)
        return CaseRunOutcome(
            run: outcome.run, result: try Self.shape(outcome.result), leak: outcome.leak)
    }

    /// The charter to hand the run loop: `nil` when the request rehearses the live charter, so
    /// `run.started` records the live version instead of 0 (a candidate).
    private func candidate(_ request: CaseRunRequest) async throws -> Charter? {
        let live = try await StewardLifecycle(sink: sink).book().records[request.steward]
        if let live, live.version == request.charterVersion, live.charter == request.charter {
            return nil
        }
        return request.charter
    }

    /// A run that failed has no result; it scores against an empty object, so it fails the
    /// case while the rehearsal still points at the failed run.
    static func shape(_ result: RunResult?) throws -> JSONValue {
        guard let result else { return .object([:]) }
        return try CanonicalJSON.jsonValue(result)
    }
}
