import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private func readyHarness() async throws -> RunHarness {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    _ = try await harness.start()
    _ = try await harness.sink.append(
        RuntimeEventDraft(
            type: StewardEventType.ready, steward: triage, actor: .localUser, payload: [:]))
    return harness
}

@Test func thePacerWaitsThenReplaysAStewardsEarlierInput() async throws {
    let harness = try await readyHarness()
    let events = try await harness.sink.events(from: 1)
    var pacer = DemoPacer()
    let start = Timestamp(millis: 1_000_000)
    #expect(try pacer.due(now: start, events: events) == nil)
    let first = try #require(pacer.nextAt)
    #expect(first.millis == start.millis + 3000)
    #expect(try pacer.due(now: start.adding(milliseconds: 2999), events: events) == nil)
    let request = try #require(try pacer.due(now: first, events: events))
    #expect(request.steward == triage)
    #expect(request.input.kind == .manual)
    #expect(request.input.text == "New issue: login page times out")
    #expect(request.mode == .live)
    let wait = try #require(pacer.nextAt).millis - first.millis
    #expect((20_000...40_000).contains(wait))
}

@Test func theJitterStaysInRangeAndRepeatsForASeed() throws {
    var one = DemoPacer(seed: 7)
    var two = DemoPacer(seed: 7)
    var now = Timestamp(millis: 0)
    var waits: [Int64] = []
    _ = try one.due(now: now, events: [])
    _ = try two.due(now: now, events: [])
    for _ in 0..<20 {
        now = try #require(one.nextAt)
        _ = try one.due(now: now, events: [])
        _ = try two.due(now: now, events: [])
        let wait = try #require(one.nextAt).millis - now.millis
        #expect(two.nextAt == one.nextAt)
        waits.append(wait)
    }
    #expect(waits.allSatisfy { (20_000...40_000).contains($0) })
    #expect(Set(waits).count > 1)
}

@Test func aStewardThatIsNotReadyIsNeverPaced() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    _ = try await harness.start()
    var pacer = DemoPacer()
    let events = try await harness.sink.events(from: 1)
    _ = try pacer.due(now: Timestamp(millis: 0), events: events)
    #expect(try pacer.due(now: Timestamp(millis: 3000), events: events) == nil)
}

@Test func theSchedulerStartsThePacedRun() async throws {
    let harness = try await readyHarness()
    let scheduler = Scheduler(engine: harness.loop)
    #expect(try await scheduler.pace(now: Timestamp(millis: 0)) == nil)
    await scheduler.setDemoPace(DemoPacer())
    #expect(try await scheduler.pace(now: Timestamp(millis: 0)) == nil)
    #expect(try await scheduler.pace(now: Timestamp(millis: 3000)) == triage)
    await scheduler.settle()
    let started = try await harness.sink.events(from: 1).filter { $0.type == "run.started" }
    #expect(started.count == 2)
    #expect(started.last?.draft.actor == .system)
}
