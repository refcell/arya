import AryaAdapters
import AryaCore
import AryaLedger
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private func filler(_ count: Int) -> [RuntimeEventDraft] {
    (0..<count).map { n in
        RuntimeEventDraft(
            type: "run.decision", steward: triage, run: RunID(unchecked: "run_old\(n)"),
            actor: .system, payload: ["choice": "noise"])
    }
}

@Test func aRunStartReadsOnlyTheEventsSinceTheLastStart() async throws {
    let harness = RunHarness(
        script: FakeScript(
            runs: [FakeScript.Run(result: triageResult), FakeScript.Run(result: triageResult)]))
    _ = try await harness.start()
    for draft in filler(500) { _ = try await harness.sink.append(draft) }
    let before = try await harness.sink.events(from: 1).count
    let foldedBefore = await harness.loop.start.folded
    _ = try await harness.start()
    let after = try await harness.sink.events(from: 1)
    let folded = await harness.loop.start.folded - foldedBefore
    // The second start and its run folded only what was appended since the first run's last
    // read, never the whole history again.
    #expect(folded > 500)
    #expect(folded <= after.count - before + 500 + 20)
    #expect(folded < after.count)
    // The cached state matches a fold of everything.
    let state = try await harness.loop.start.current(harness.sink)
    #expect(state.seq == after.last?.seq)
    #expect(state.plans.plans == (try PlanBook(after)).plans)
    #expect(
        state.effects.effects(triage, metric: triageCharter().metric)
            == (try Effectiveness.of(triage, in: after)))
}

// Perf probe, only with `ARYA_PERF=1 just test AryaRuntimeTests`, never in CI: a warm run start
// (steward lookup, plan, memory, what has worked, instructions) on a 50,000-event home.
private let perfEnabled = ProcessInfo.processInfo.environment["ARYA_PERF"] == "1"

@Test(.enabled(if: perfEnabled)) func perfWarmRunStartOn50000EventsIsUnder10ms() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-start-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let ambient = Ambient.fixed()
    let store = try LedgerStore(home: home, ambient: ambient)
    let sink = LedgerEventSink(store: store)
    try await StewardLifecycle(sink: sink).create(triageCharter())
    try store.append(filler(50_000).map(\.ledgerDraft))
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let engine = RunEngine(
        sink: sink, ambient: ambient, adapters: FakeFactory(script: FakeScript(runs: [])),
        dispatcher: ActionDispatcher(
            sink: sink, approvals: approvals, executor: RecordingExecutor()),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    let request = RunRequest.manual(triage, text: "New issue: login page times out")
    func start() async throws {
        let steward = try await sink.book(StewardBook.self).records[triage]
        _ = try await engine.prepare(request, try #require(steward).charter)
    }
    let clock = ContinuousClock()
    let cold = try await clock.measure { try await start() }
    try store.append(filler(3).map(\.ledgerDraft))
    let warm = try await clock.measure { try await start() }
    try store.append(filler(3).map(\.ledgerDraft))
    let book = try await clock.measure { _ = try await sink.book(StewardBook.self) }
    try store.append(filler(3).map(\.ledgerDraft))
    let state = try await clock.measure { _ = try await engine.start.current(sink) }
    try store.append(filler(3).map(\.ledgerDraft))
    let tail = try await clock.measure { _ = try await sink.events(from: 50_005) }
    print("PERF run start on 50k events: cold \(cold), warm \(warm)")
    print("PERF parts: steward book \(book), start state \(state), ledger tail \(tail)")
    #expect(warm < .milliseconds(10))
}
