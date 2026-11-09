import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

/// A sink that stops accepting writes when "killed", like a process that died mid-run.
actor KillableSink: EventSink {
    let inner: MemoryEventSink
    private var dead = false

    init(_ inner: MemoryEventSink) { self.inner = inner }

    func kill() { dead = true }

    func append(_ draft: RuntimeEventDraft) async throws -> RuntimeEvent {
        guard !dead else { throw CancellationError() }
        return try await inner.append(draft)
    }

    func events(from seq: Int) async throws -> [RuntimeEvent] {
        try await inner.events(from: seq)
    }
}

private struct Rig {
    let store: MemoryEventSink
    let sink: KillableSink
    let leases = MemoryRunLeases()
    let loop: RunEngine
    let approvals: ApprovalQueue

    init(_ run: FakeScript.Run) {
        let ambient = Ambient.fixed()
        store = MemoryEventSink(ambient: ambient)
        sink = KillableSink(store)
        approvals = ApprovalQueue(sink: sink, ambient: ambient)
        loop = RunEngine(
            sink: sink, ambient: ambient, adapters: FakeFactory(script: FakeScript(runs: [run])),
            dispatcher: ActionDispatcher(
                sink: sink, approvals: approvals, executor: RecordingExecutor()),
            approvals: approvals, workdir: { "scratch/\($0.rawValue)" }, leases: leases)
    }
}

@Test func killedRunIsInterruptedOnRestartAndApprovalsSurvive() async throws {
    let rig = Rig(FakeScript.Run(steps: [toolCall, .hang]))
    let charter = triageCharter()
    try await StewardLifecycle(sink: rig.sink).create(charter)
    let pending = try await rig.approvals.request(
        .question("Earlier question"), steward: charter.id, run: RunID(unchecked: "run_old"))
    let before = try await rig.approvals.book()

    let running = Task { try await rig.loop.run(.manual(charter.id, text: "go")) }
    // Wait until the adapter is streaming, then kill the "process" mid-stream.
    while try await !rig.store.events(from: 1).contains(where: {
        $0.payload.objectValue?["message"]?.objectValue?["method"] == "run/event"
    }) {
        try await Task.sleep(for: .milliseconds(1))
    }
    await rig.sink.kill()
    running.cancel()
    _ = try? await running.value

    let open = try RunBook(try await rig.store.events(from: 1)).open
    #expect(open.count == 1)
    #expect(!rig.leases.isHeld(open[0].id))

    // A new process: fresh sink over the same events, same leases.
    let recovered = try await RunRecovery(sink: rig.store, leases: rig.leases).recover()
    #expect(recovered.map(\.id) == open.map(\.id))
    let book = try RunBook(try await rig.store.events(from: 1))
    #expect(book.records[open[0].id]?.status == .failed)
    #expect(book.records[open[0].id]?.failureReason == "interrupted")
    #expect(book.open.isEmpty)

    let after = try ApprovalBook(try await rig.store.events(from: 1))
    #expect(after.pending == before.pending)
    #expect(after.pending.map(\.id) == [pending.id])

    // Recovering again changes nothing.
    #expect(try await RunRecovery(sink: rig.store, leases: rig.leases).recover().isEmpty)
}

@Test func heldRunIsLeftAlone() async throws {
    let sink = MemoryEventSink(ambient: .fixed())
    let leases = MemoryRunLeases()
    let run = RunID(unchecked: "run_live")
    let payload = RunStartedPayload(
        trigger: "manual", input: RunInput(kind: .manual, text: "x"), parent: nil,
        charterVersion: 1, adapter: "fake", effort: "medium", instructions: "", memory: [],
        routines: [], rehearsal: false)
    _ = try await sink.append(
        RuntimeEventDraft(
            type: RunEventType.started, steward: StewardID(unchecked: "st_triage"), run: run,
            actor: .localUser, payload: try Payload.encode(payload)))
    let lease = try leases.acquire(run)
    #expect(try await RunRecovery(sink: sink, leases: leases).recover().isEmpty)
    lease.release()
    #expect(try await RunRecovery(sink: sink, leases: leases).recover().map(\.id) == [run])
}

@Test func finishedRunsAreProjected() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    let outcome = try await harness.start()
    let record = try #require(
        try RunBook(try await harness.sink.events(from: 1)).records[outcome.run])
    #expect(record.status == .finished)
    #expect(record.endStatus == "completed")
    #expect(record.trigger == "manual")
    #expect(record.actions == 2)
    #expect(record.summary == "Labeled ISSUE-7 as a bug.")
}

@Test func fileLeasesAreExclusiveAndFreedOnRelease() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-leases-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let leases = try FileRunLeases(directory: directory)
    let run = RunID(unchecked: "run_000001")
    #expect(!leases.isHeld(run))
    let lease = try leases.acquire(run)
    #expect(leases.isHeld(run))
    #expect(throws: RunLeaseError.self) { try leases.acquire(run) }
    lease.release()
    #expect(!leases.isHeld(run))
    lease.release()
}
