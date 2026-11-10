import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

/// The M3.5 backtest scenario in `Fixtures/backtest` (see its README).
enum BacktestScenario {
    static let cardRule = "A question about the card on file is a billing question."

    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name, withExtension: nil, subdirectory: "Fixtures/backtest"))
        return try Data(contentsOf: url)
    }

    static func charter(_ name: String) throws -> Charter {
        try CanonicalJSON.decode(Charter.self, from: try data("charter-\(name).json"))
    }

    static func script(_ name: String) throws -> FakeScript {
        try JSONDecoder().decode(FakeScript.self, from: try data("fake-\(name).json"))
    }
}

/// Scripts the fake adapter by charter: the proposed charter carries the card-on-file rule.
private struct ScenarioAdapters: AdapterFactory {
    let current: FakeScript
    let proposed: FakeScript

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        FakeAdapter(
            script: charter.guardrails.contains(BacktestScenario.cardRule) ? proposed : current)
    }
}

/// Runs each case through the engine in rehearsal mode with the variant's charter.
private struct ScenarioRunner: CaseRunner {
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

extension BacktestScenario {
    /// Rehearses the fixture's current and proposed charters and compares them.
    static func compare() async throws -> BacktestComparison { try await run().comparison }

    static func run() async throws -> (
        comparison: BacktestComparison, sink: MemoryEventSink, steward: StewardID
    ) {
        let ambient = Ambient.fixed(stepMillis: 3, seed: 35)
        let sink = MemoryEventSink(ambient: ambient)
        let blobs = MemoryBlobs()
        let current = try BacktestScenario.charter("current")
        let proposed = try BacktestScenario.charter("proposed")
        try await StewardLifecycle(sink: sink).create(current)
        let (book, _) = try await CasebookImporter(blobs: blobs, sink: sink).importCasebook(
            name: "triage", data: try BacktestScenario.data("casebook.jsonl"), steward: current.id)
        let approvals = ApprovalQueue(sink: sink, ambient: ambient)
        let engine = RunEngine(
            sink: sink, ambient: ambient,
            adapters: ScenarioAdapters(
                current: try BacktestScenario.script("current"),
                proposed: try BacktestScenario.script("proposed")),
            dispatcher: ActionDispatcher(
                sink: sink, approvals: approvals, executor: RecordingExecutor(outcomes: [:])),
            approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
        let casebooks = StoredCasebooks(sink: sink, blobs: blobs)
        let rehearser = CasebookRehearser(
            runner: ScenarioRunner(engine: engine), casebooks: casebooks, sink: sink,
            ambient: ambient)

        let comparison = try await Backtester(
            rehearser: rehearser, reports: RehearsalReports(sink: sink, casebooks: casebooks)
        ).run(
            steward: current.id, casebookVersion: book.version,
            current: BacktestVariant(charterVersion: 1, charter: current),
            proposed: BacktestVariant(charterVersion: 0, charter: proposed),
            tolerance: current.gate.tolerance)
        return (comparison, sink, current.id)
    }
}

@Test func backtestScenarioHasOneImprovedAndOneRegressedCase() async throws {
    let (comparison, sink, steward) = try await BacktestScenario.run()

    #expect(comparison.cases.count == 8)
    #expect(comparison.current.passed == 7 && comparison.proposed.passed == 7)
    let changed = comparison.cases.filter { $0.change != .unchanged }
    #expect(changed.map(\.caseID.rawValue) == ["case-0005", "case-0006"])
    #expect(changed.map(\.change) == [.regressed, .improved])
    #expect(!comparison.verdict.passed)
    #expect(comparison.verdict.regressions.map(\.rawValue) == ["case-0005"])
    #expect(
        comparison.summary
            == "proposed: 1 improved, 1 regressed (mean 0.96 to 0.96); gate fails: case regressed")
    #expect(
        changed[1].summary
            == "case-0006 improved: now chose billing; label inbox:MSG-106, route inbox:MSG-106 "
            + "(was chose how-to; label inbox:MSG-106, route inbox:MSG-106)")
    #expect(changed[1].current.diffText == "decisions[0].choice: expected billing, got how-to")
    #expect(changed[1].proposed.diffText == "matches expected")
    #expect(
        changed[0].expectedText
            == "chose security; label inbox:MSG-105, route inbox:MSG-105")
    #expect(comparison.cases[0].summary == "case-0001 unchanged: passes both ways")

    // Readiness of the live (current) charter after the backtest.
    let readiness = try await ReadinessReports(sink: sink).report(steward)
    #expect(readiness.summary == "not ready: 7/8 passed, 100% required")
}

@Test func resultTextReadsWithoutFormatting() {
    #expect(ResultText.describe(nil) == "no result")
    #expect(ResultText.describe([:]) == "nothing")
    #expect(
        ResultText.describe([
            "summary": "ignored", "decisions": [["choice": "bug"]],
            "actions": [["kind": "label", "target": "tracker:ISSUE-1"]], "score": 0.5,
        ]) == "chose bug; label tracker:ISSUE-1; score 0.5")
    #expect(
        ResultText.describe([
            FieldDiff(path: "actions[1]", expected: .none, actual: ["kind": "route"]),
            FieldDiff(path: "decisions[0].choice", expected: "bug", actual: .none),
        ]) == "actions[1]: unexpected route; decisions[0].choice: expected bug, got nothing")
    #expect(ResultText.describe([FieldDiff]()) == "matches expected")
    #expect(ResultText.value(1.0) == "1")
}
