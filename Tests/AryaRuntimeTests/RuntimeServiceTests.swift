import AryaAdapters
import AryaCore
import Testing

@testable import AryaRuntime

private actor Announcements: ApprovalNotifier {
    private(set) var batches: [[ApprovalID]] = []
    func pending(_ approvals: [ApprovalRecord]) async { batches.append(approvals.map(\.id)) }
}

private func readyHarness() async throws -> RunHarness {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    var charter = triageCharter()
    charter.triggers = [.interval(everySeconds: 900)]
    try await harness.lifecycle.create(charter)
    _ = try await harness.sink.append(
        RuntimeEventDraft(
            type: StewardEventType.ready, steward: charter.id, actor: .localUser, payload: [:]))
    return harness
}

private let t0 = Timestamp(millis: 1_000_000_000_000)

@Test func tickSchedulesRunsAndAnnouncesTheirApprovalsOnce() async throws {
    let harness = try await readyHarness()
    let notes = Announcements()
    let service = RuntimeService(
        engine: harness.loop,
        recovery: RunRecovery(sink: harness.sink, leases: MemoryRunLeases()), notifier: notes)
    let first = try await service.tick(now: t0)
    #expect(first.scheduled == [StewardID(unchecked: "st_triage")])
    await service.settle()

    let second = try await service.tick(now: t0)
    #expect(second.scheduled.isEmpty)
    let pending = try await harness.approvals.book().pending.map(\.id)
    #expect(!pending.isEmpty)
    #expect(second.announced == pending)
    let third = try await service.tick(now: t0)
    #expect(third.announced.isEmpty)
    #expect(await notes.batches == [pending])
}

@Test func tickExpiresDueApprovals() async throws {
    let harness = try await readyHarness()
    let service = RuntimeService(
        engine: harness.loop,
        recovery: RunRecovery(sink: harness.sink, leases: MemoryRunLeases()))
    let question = try await harness.approvals.request(
        .question("Which label?"), steward: StewardID(unchecked: "st_triage"),
        run: RunID(unchecked: "run_01"), to: "local", expiresAt: t0)
    let tick = try await service.tick(now: t0.adding(milliseconds: 1))
    #expect(tick.expired == [question.id])
    #expect(!tick.announced.contains(question.id))
    await service.settle()
}
