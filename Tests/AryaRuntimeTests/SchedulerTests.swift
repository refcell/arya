import AryaAdapters
import AryaCore
import AryaLedger
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private func scheduledCharter(_ triggers: [Trigger] = [.interval(everySeconds: 900), .manual])
    -> Charter
{
    var charter = triageCharter()
    charter.bindings.append(.person("alex", channel: "local"))
    charter.triggers = triggers
    return charter
}

private struct SchedulerRig {
    let harness: RunHarness
    let scheduler: Scheduler

    init() {
        harness = RunHarness(FakeScript.Run(result: triageResult))
        scheduler = Scheduler(engine: harness.loop)
    }

    func create(_ charter: Charter = scheduledCharter(), ready: Bool = true) async throws {
        try await harness.lifecycle.create(charter)
        if ready {
            _ = try await harness.sink.append(
                RuntimeEventDraft(
                    type: StewardEventType.ready, steward: charter.id, actor: .localUser,
                    payload: [:]))
        }
    }

    func plan(at now: Timestamp) async throws -> [StewardID] {
        let events = try await harness.sink.events(from: 1)
        return SchedulePlan.due(
            stewards: try StewardBook(events), runs: try RunBook(events), now: now)
    }

    func runs() async throws -> [RunRecord] {
        try RunBook(try await harness.sink.events(from: 1)).all
    }
}

private let t0 = Timestamp(millis: 1_000_000_000_000)

@Test func onlyReadyActiveStewardsWithAnIntervalAreDue() async throws {
    let ready = SchedulerRig()
    try await ready.create()
    #expect(try await ready.plan(at: t0) == [triage])

    let unready = SchedulerRig()
    try await unready.create(ready: false)
    #expect(try await unready.plan(at: t0).isEmpty)

    let paused = SchedulerRig()
    try await paused.create()
    try await paused.harness.lifecycle.pause(triage)
    #expect(try await paused.plan(at: t0).isEmpty)

    let manualOnly = SchedulerRig()
    try await manualOnly.create(scheduledCharter([.manual]))
    #expect(try await manualOnly.plan(at: t0).isEmpty)
}

@Test func tickStartsOneScheduledRunAndWaitsOneInterval() async throws {
    let rig = SchedulerRig()
    try await rig.create()
    #expect(try await rig.scheduler.tick(now: t0) == [triage])
    // A second tick before the run ends does not start another.
    #expect(try await rig.scheduler.tick(now: t0).isEmpty)
    await rig.scheduler.settle()

    let runs = try await rig.runs()
    #expect(runs.count == 1)
    #expect(runs[0].trigger == "schedule")
    #expect(runs[0].status == .finished)
    let started = try #require(try await rig.harness.last("run.started"))
    #expect(started.draft.actor == .system)

    let last = runs[0].startedAt
    #expect(try await rig.plan(at: last.adding(milliseconds: 899_999)).isEmpty)
    #expect(try await rig.plan(at: last.adding(milliseconds: 900_000)) == [triage])
    // A manual run does not reset the schedule.
    _ = try await rig.harness.start(charter: scheduledCharter())
    #expect(try await rig.plan(at: last.adding(milliseconds: 900_000)) == [triage])
}

@Test func interruptedScheduledRunIsRequeuedAfterRestart() async throws {
    let rig = SchedulerRig()
    try await rig.create()
    let run = RunID(unchecked: "run_01")
    let payload = RunStarted(
        input: RunInputRecord(kind: .schedule, text: "Scheduled run."), charterVersion: 1,
        adapter: "fake", effort: .medium, instructions: "", limits: Limits())
    _ = try await rig.harness.sink.append(
        RuntimeEventDraft(
            type: RunEventType.started, steward: triage, run: run, actor: .system,
            payload: try Payload.encode(payload)))
    // Open run: not due, the run may still be going.
    #expect(try await rig.plan(at: t0.adding(milliseconds: 10_000_000)).isEmpty)

    let recovered = try await RunRecovery(sink: rig.harness.sink, leases: MemoryRunLeases())
        .recover()
    #expect(recovered.map(\.id) == [run])
    // Interrupted: due right away, not one interval later.
    let startedAt = try #require(try await rig.runs().first?.startedAt)
    #expect(try await rig.plan(at: startedAt) == [triage])
}

@Test func messageTriggersMatchTheSender() async throws {
    let rig = SchedulerRig()
    try await rig.create(scheduledCharter([.message(from: "alex")]))
    #expect(try await !rig.scheduler.deliver("hi", from: "sam", to: triage))
    #expect(try await rig.scheduler.deliver("ISSUE-7 is back", from: "alex", to: triage))
    await rig.scheduler.settle()
    let runs = try await rig.runs()
    #expect(runs.map(\.trigger) == ["message"])
    #expect(runs.first?.input == "ISSUE-7 is back")
    let started = try #require(try await rig.harness.last("run.started"))
    #expect(started.draft.actor == .person("alex"))

    let unready = SchedulerRig()
    try await unready.create(scheduledCharter([.message(from: nil)]), ready: false)
    #expect(try await !unready.scheduler.deliver("hi", from: "alex", to: triage))
}

@Test func onlyOneProcessHoldsTheSchedulerLock() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-sched-\(ProcessInfo.processInfo.globallyUniqueString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let first = try #require(try SchedulerLock.acquire(home: home))
    #expect(try SchedulerLock.acquire(home: home) == nil)
    first.release()
    let second = try SchedulerLock.acquire(home: home)
    #expect(second != nil)
}
