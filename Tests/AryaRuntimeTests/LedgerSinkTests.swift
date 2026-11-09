import AryaAdapters
import AryaCore
import AryaLedger
import Foundation
import Testing

@testable import AryaRuntime

private func tempHome() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-runtime-\(ProcessInfo.processInfo.globallyUniqueString)")
}

private func engine(_ sink: any EventSink, _ ambient: Ambient, _ executor: RecordingExecutor)
    -> (RunEngine, ApprovalQueue, ActionDispatcher)
{
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let dispatcher = ActionDispatcher(sink: sink, approvals: approvals, executor: executor)
    let engine = RunEngine(
        sink: sink, ambient: ambient,
        adapters: FakeFactory(
            script: FakeScript(runs: [FakeScript.Run(steps: [toolCall], result: triageResult)])),
        dispatcher: dispatcher, approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    return (engine, approvals, dispatcher)
}

@Test func manualRunLandsOnTheVerifiedLedgerAndSurvivesRestart() async throws {
    let home = tempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let ambient = Ambient.fixed()
    let executor = RecordingExecutor()

    // First process: create the steward and run it.
    let sink = try LedgerEventSink(home: home, ambient: ambient)
    try await StewardLifecycle(sink: sink).create(triageCharter())
    let (first, _, _) = engine(sink, ambient, executor)
    let outcome = try await first.run(.manual(StewardID(unchecked: "st_triage"), text: "go"))
    #expect(outcome.phase == .finished(.completed))

    let verification = try LedgerVerifier(home: home).verify()
    #expect(verification.ok)
    let types = try LedgerReader(home: home).events().map(\.type.rawValue)
    #expect(types.first == "steward.created")
    #expect(types.last == "run.finished")
    #expect(types.contains("run.adapter.event"))

    // Second process: a fresh sink over the same home sees the pending approval and grants it.
    let reopened = try LedgerEventSink(home: home, ambient: Ambient.fixed(stepMillis: 7))
    #expect(try await RunRecovery(sink: reopened, leases: MemoryRunLeases()).recover().isEmpty)
    let (_, approvals, dispatcher) = engine(reopened, ambient, executor)
    let pending = try await approvals.book().pending
    #expect(pending.count == 1)
    let granted = try await approvals.grant(pending[0].id, by: .localUser)
    let charter = try #require(
        try await StewardLifecycle(sink: reopened).book().records[
            StewardID(unchecked: "st_triage")]?.charter)
    #expect(
        try await dispatcher.executeGranted(granted, charter: charter)
            == .succeeded(
                output: ["ok": true]))
    #expect(await executor.requests.map(\.action.id) == ["a1", "a2"])
    #expect(try LedgerVerifier(home: home).verify().ok)

    let events = try LedgerReader(home: home).events()
    #expect(events.last?.type == EventType.actionExecuted)
    #expect(events.last?.run == outcome.run)
    let wire = events.first { $0.type == EventType.runAdapterEvent }
    #expect(wire?.actor == Actor(kind: .adapter, id: "fake"))
}

@Test func runtimeActorsRoundTripThroughTheLedger() {
    for actor in [RuntimeActor.localUser, .system, .person("person:alex"), .adapter("fake")] {
        #expect(RuntimeActor(actor.ledgerActor) == actor)
    }
    #expect(RuntimeActor(kind: "robot", id: "x").ledgerActor.kind == .system)
}
