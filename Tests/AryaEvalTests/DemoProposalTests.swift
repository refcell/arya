import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

/// `etc/examples/triage` at the repository root.
let examples = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("etc/examples/triage")

/// Picks the script by the charter's adapter profile, as the demo's adapters.json would.
struct ProfileAdapters: AdapterFactory {
    let scripts: [String: FakeScript]

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        guard let script = scripts[charter.adapter] else {
            throw EvalError.notImplemented(charter.adapter)
        }
        return FakeAdapter(script: script)
    }
}

struct ProfileRunner: CaseRunner {
    let engine: RunEngine

    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let item = request.caseItem
        var run = RunRequest(
            steward: request.steward,
            input: RunInput(kind: .case, text: item.input.text, attachments: []),
            mode: .rehearsal(item.context), actor: .system, charter: request.charter)
        run.rehearsal = RehearsalTag(
            rehearsal: request.rehearsal, caseID: item.id, sample: request.sample + 1)
        let outcome = try await engine.run(run)
        let result = try outcome.result.map { try CanonicalJSON.jsonValue($0) } ?? [:]
        return CaseRunOutcome(run: outcome.run, result: result, leak: outcome.leak)
    }
}

/// The demo home's proposed charter v2 (`etc/examples/triage/charter-v2.json`) against the
/// example charter on the example casebook as imported: one improved and one regressed case.
@Test func demoProposalHasOneImprovedAndOneRegressedCase() async throws {
    let live = try CanonicalJSON.decode(
        Charter.self, from: try Data(contentsOf: examples.appendingPathComponent("charter.json")))
    let v2 = try CanonicalJSON.decode(
        Charter.self, from: try Data(contentsOf: examples.appendingPathComponent("charter-v2.json"))
    )
    let ambient = Ambient.fixed(stepMillis: 2, seed: 77)
    let sink = MemoryEventSink(ambient: ambient)
    let blobs = MemoryBlobs()
    try await StewardLifecycle(sink: sink).create(live)
    let (book, _) = try await CasebookImporter(blobs: blobs, sink: sink).importCasebook(
        name: "triage",
        data: try Data(contentsOf: examples.appendingPathComponent("casebook.jsonl")),
        steward: live.id)
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let engine = RunEngine(
        sink: sink, ambient: ambient,
        adapters: ProfileAdapters(scripts: [
            live.adapter: try FakeScript.load(
                from: examples.appendingPathComponent("fake-script.json")),
            v2.adapter: try JSONDecoder().decode(
                FakeScript.self,
                from: try Data(contentsOf: examples.appendingPathComponent("fake-script-v2.json"))),
        ]),
        dispatcher: ActionDispatcher(
            sink: sink, approvals: approvals, executor: RecordingExecutor(outcomes: [:])),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    let casebooks = StoredCasebooks(sink: sink, blobs: blobs)
    let rehearser = CasebookRehearser(
        runner: ProfileRunner(engine: engine), casebooks: casebooks, sink: sink, ambient: ambient)

    let comparison = try await Backtester(
        rehearser: rehearser, reports: RehearsalReports(sink: sink, casebooks: casebooks)
    ).run(
        steward: live.id, casebookVersion: book.version,
        current: BacktestVariant(charterVersion: 1, charter: live),
        proposed: BacktestVariant(charterVersion: 0, charter: v2), tolerance: live.gate.tolerance)

    #expect(comparison.current.passed == 7 && comparison.proposed.passed == 7)
    let changed = comparison.cases.filter { $0.change != .unchanged }
    #expect(changed.map(\.caseID.rawValue) == ["case-0005", "case-0006"])
    #expect(changed.map(\.change) == [.regressed, .improved])
    #expect(!comparison.verdict.passed && comparison.verdict.reason == "case regressed")
}

/// The example rubric judge (`etc/examples/triage/judge`) on the example casebook: seven of
/// eight pass, and each score reads as one sentence.
@Test func judgeExampleScoresInSentences() async throws {
    let live = try CanonicalJSON.decode(
        Charter.self, from: try Data(contentsOf: examples.appendingPathComponent("charter.json")))
    let judgeDir = examples.appendingPathComponent("judge")
    let ambient = Ambient.fixed(stepMillis: 2, seed: 78)
    let sink = MemoryEventSink(ambient: ambient)
    let blobs = MemoryBlobs()
    try await StewardLifecycle(sink: sink).create(live)
    let (book, _) = try await CasebookImporter(blobs: blobs, sink: sink).importCasebook(
        name: "triage",
        data: try Data(contentsOf: examples.appendingPathComponent("casebook.jsonl")),
        steward: live.id)
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let engine = RunEngine(
        sink: sink, ambient: ambient,
        adapters: ProfileAdapters(scripts: [
            live.adapter: try FakeScript.load(
                from: examples.appendingPathComponent("fake-script.json"))
        ]),
        dispatcher: ActionDispatcher(
            sink: sink, approvals: approvals, executor: RecordingExecutor(outcomes: [:])),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    let casebooks = StoredCasebooks(sink: sink, blobs: blobs)
    let judge = try CaseVerdicts(
        data: try Data(contentsOf: judgeDir.appendingPathComponent("verdicts.json")))
    let rubric = try String(
        contentsOf: judgeDir.appendingPathComponent("rubric.md"), encoding: .utf8)
    let rehearser = CasebookRehearser(
        runner: ProfileRunner(engine: engine), casebooks: casebooks, sink: sink,
        ambient: ambient, judge: judge, rubric: rubric)

    let result = try await rehearser.rehearse(
        RehearsalRequest(steward: live.id, charterVersion: 1, casebookVersion: book.version),
        charter: live)
    let scores = Dictionary(
        uniqueKeysWithValues: result.outcomes.map {
            ($0.caseID.rawValue, $0.samples[0])
        })
    #expect(scores.values.filter(\.passed).count == 7)
    #expect(scores["case-0001"]?.sentence == "polite, no reply needed, followed policy")
    #expect(
        scores["case-0006"]?.sentence
            == "polite, no reply needed, routed a how-to question to billing")
    #expect(scores["case-0006"]?.value == 0.5)
    let report = try await RehearsalReports(sink: sink, casebooks: casebooks).report(
        try #require(result.id))
    #expect(
        report.cases.first { $0.caseID.rawValue == "case-0006" }?.samples.first?.judgment?.judge
            == "triage-rubric")
}
