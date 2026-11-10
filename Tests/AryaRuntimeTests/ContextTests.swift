import AryaAdapters
import AryaCore
import AryaMemory
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

@Test func contextGathersPeopleConnectionsAndNotes() async throws {
    let harness = RunHarness(script: FakeScript(runs: [FakeScript.Run(result: triageResult)]))
    var charter = triageCharter()
    charter.bindings.append(.person("alex", channel: "alex@example.com"))
    charter.triggers = [.manual]
    try await harness.lifecycle.create(charter)
    _ = try await harness.sink.append(
        RuntimeEventDraft(
            type: StewardEventType.ready, steward: triage, actor: .localUser, payload: [:]))
    let inbox = Inbox(engine: harness.loop, scheduler: Scheduler(engine: harness.loop))
    _ = try await inbox.post("Is ISSUE-7 urgent?", from: "alex", to: triage)
    _ = try await inbox.post(
        "Only label the tracker after triage", from: "alex", to: triage, intent: .correct)

    let outcome = try await harness.start(charter: charter)  // label auto, comment asks
    let approval = try #require(outcome.disposals.compactMap(\.approval).first)
    _ = try await harness.approvals.deny(approval, by: .person("sam"), note: "no")

    let context = try #require(
        try StewardContext(try await harness.sink.events(from: 1), steward: triage))
    #expect(context.people.map(\.id) == ["alex", "sam"])
    let alex = context.people[0]
    #expect(alex.bound)
    #expect(alex.channel == "alex@example.com")
    #expect(alex.messages == 2)
    #expect(alex.corrections == 1)
    #expect(alex.notes.count == 1)  // the correction, written by alex
    let sam = context.people[1]
    #expect(!sam.bound)
    #expect(sam.decisions == 1)

    let tracker = try #require(context.connections.first { $0.id == "tracker" })
    #expect(tracker.actionsExecuted == 1)
    #expect(tracker.notes.count == 1)  // the correction names the tracker
    #expect(try StewardContext([], steward: triage) == nil)
}
