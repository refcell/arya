import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

/// The fake adapter per run, answering every case with the same scripted result.
private struct FiftyAdapters: AdapterFactory {
    let script = FakeScript(runs: [
        FakeScript.Run(result: ["summary": "ok", "decisions": [["id": "d1", "choice": "bug"]]])
    ])

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        FakeAdapter(script: script)
    }
}

private struct EngineRunner: CaseRunner {
    let engine: RunEngine

    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let item = request.caseItem
        var run = RunRequest(
            steward: request.steward,
            input: RunInput(kind: .case, text: item.input.text, attachments: []),
            mode: .rehearsal(item.context), actor: .system)
        run.rehearsal = RehearsalTag(
            rehearsal: request.rehearsal, caseID: item.id, sample: request.sample + 1)
        let outcome = try await engine.run(run)
        let result = try outcome.result.map { try CanonicalJSON.jsonValue($0) } ?? [:]
        return CaseRunOutcome(run: outcome.run, result: result, leak: outcome.leak)
    }
}

/// A 50-case rehearsal through the real run engine and the in-memory fake adapter must finish
/// in under 10 s even on a loaded machine (it takes well under a second when idle).
@Test func fiftyCaseRehearsalIsFast() async throws {
    let ambient = Ambient.fixed(stepMillis: 1, seed: 50)
    let sink = MemoryEventSink(ambient: ambient)
    let charter = Charter(
        id: StewardID(unchecked: "st_perf"), name: "Perf", outcome: "Fast rehearsals.",
        metric: Metric(name: "speed", unit: "ratio", direction: .up), adapter: "fake")
    try await StewardLifecycle(sink: sink).create(charter)
    let book = try Casebook(
        name: "perf",
        cases: (1...50).map {
            Case(
                id: CaseID(rawValue: String(format: "case-%04d", $0))!,
                input: CaseInput(text: "Issue \($0)"),
                expected: ["decisions": [["choice": "bug"]]])
        })
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let engine = RunEngine(
        sink: sink, ambient: ambient, adapters: FiftyAdapters(),
        dispatcher: ActionDispatcher(
            sink: sink, approvals: approvals, executor: RecordingExecutor(outcomes: [:])),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    let rehearser = CasebookRehearser(
        runner: EngineRunner(engine: engine), casebooks: FixedCasebooks(book: book), sink: sink,
        ambient: ambient, maxParallel: 4)

    let clock = ContinuousClock()
    let started = clock.now
    let result = try await rehearser.rehearse(
        RehearsalRequest(steward: charter.id, charterVersion: 1, casebookVersion: book.version),
        charter: charter)
    let elapsed = clock.now - started

    #expect(result.outcomes.count == 50)
    #expect(result.outcomes.allSatisfy { $0.samples.first?.passed == true })
    #expect(elapsed < .seconds(10), "50-case rehearsal took \(elapsed)")
}
