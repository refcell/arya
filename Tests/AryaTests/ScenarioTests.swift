import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import Arya

/// The triage example the `just e2e` scenario runs (etc/examples/triage).
private let example = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("etc/examples/triage")

private func exampleFile(_ name: String) throws -> Data {
    try Data(contentsOf: example.appendingPathComponent(name))
}

/// The M3 scenario of `etc/scripts/e2e.sh`, step by step, through the facade with the fake
/// adapter in process: create, import, rehearse 7/8, correct, rehearse 8/8, ready, live run,
/// approval, execution, metric, replay with zero divergence, verify.
@Test func m3ScenarioThroughTheFacade() async throws {
    let script = try JSONDecoder().decode(
        FakeScript.self, from: try exampleFile("fake-script.json"))
    let home = TempHome()
    let workspace = try await Workspace.open(
        home: home.url,
        wiring: Wiring(
            ambient: .fixed(stepMillis: 1), adapters: ScriptedFactory(script: script),
            executor: RecordingExecutor(), leases: MemoryRunLeases(),
            questionPoll: .milliseconds(1)))

    let steward = try await workspace.createSteward(charter: try exampleFile("charter.json"))
    #expect(steward.id == "st_triage")
    #expect(!steward.ready)

    let casebook = try await workspace.importCasebook(
        steward: "st_triage", data: try exampleFile("casebook.jsonl"), name: "triage")
    #expect(casebook.cases == 8)

    let first = try await workspace.rehearse(steward: "st_triage")
    #expect(first.passed == 7)
    #expect(first.total == 8)
    #expect(first.failed == ["case-0006"])

    let expected = try await workspace.expected(
        steward: "st_triage", case: "case-0006", choice: "billing")
    let correction = try await workspace.correct(
        steward: "st_triage", case: "case-0006", expected: expected, note: nil)
    #expect(correction.caseID == "case-0006")

    let second = try await workspace.rehearse(steward: "st_triage")
    #expect(second.passed == 8)
    #expect(second.total == 8)

    #expect(try await workspace.markReady(steward: "st_triage").ready)

    let run = try await workspace.startRun(
        steward: "st_triage", input: "New message MSG-201: Refund for a duplicate charge")
    let detail = try #require(try await workspace.run(run.id))
    #expect(detail.actions.map(\.disposition) == [.executed, .executed, .held])
    let held = try #require(detail.actions.last?.approval)

    let pending = try await workspace.approvals()
    #expect(pending.map(\.id) == [held])
    #expect(try await workspace.approve(held, note: "looks right").status == .granted)

    let ledger = try await workspace.ledger()
    let own = ledger.filter { $0.steward == "st_triage" }
    #expect(own.filter { $0.type == "action.executed" }.count == 3)
    #expect(own.contains { $0.type == "metric.recorded" && $0.run == run.id })

    let metrics = try await workspace.metrics(steward: "st_triage")
    #expect(metrics.metric == "routed_within_1h")
    #expect(metrics.windows.contains { $0.counts["routed_within_1h"] == 1 })

    #expect(try await workspace.replay(run: run.id).divergences == [])
    #expect(try await workspace.verifyLedger().ok)
}
