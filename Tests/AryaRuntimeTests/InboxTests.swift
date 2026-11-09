import AryaAdapters
import AryaCore
import AryaLedger
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private struct InboxRig {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    let scheduler: Scheduler
    let inbox: Inbox

    init() {
        scheduler = Scheduler(engine: harness.loop)
        inbox = Inbox(engine: harness.loop, scheduler: scheduler)
    }

    func create(_ triggers: [Trigger] = [.manual, .message(from: "alex")]) async throws {
        var charter = triageCharter()
        charter.bindings.append(.person("alex", channel: "local"))
        charter.triggers = triggers
        try await harness.lifecycle.create(charter)
        _ = try await harness.sink.append(
            RuntimeEventDraft(
                type: StewardEventType.ready, steward: triage, actor: .localUser, payload: [:]))
    }

    func events(_ type: String) async throws -> [RuntimeEvent] {
        try await harness.sink.events(from: 1).filter { $0.type == type }
    }
}

@Test func aCorrectionBecomesMemoryAndStartsARun() async throws {
    let rig = InboxRig()
    try await rig.create()
    let receipt = try await rig.inbox.post(
        "  ISSUE-7 is a duplicate of ISSUE-3  ", from: "alex", to: triage, intent: .correct)
    await rig.scheduler.settle()
    #expect(receipt.triggered)

    let message = try #require(try await rig.events(InboxEventType.message).first)
    #expect(message.draft.actor == .person("alex"))
    #expect(message.payload["text"] == "ISSUE-7 is a duplicate of ISSUE-3")
    #expect(message.payload["channel"] == "local")
    #expect(message.payload["intent"] == "correct")

    let added = try #require(try await rig.events("memory.added").first)
    #expect(added.draft.actor == .person("alex"))
    #expect(added.payload["note"]?["id"] == message.payload["note"])
    #expect(added.payload["note"]?["provenance"]?["event"]?.stringValue == message.id.rawValue)
    #expect(receipt.note?.rawValue == message.payload["note"]?.stringValue)

    let started = try #require(try await rig.harness.last("run.started"))
    #expect(started.draft.actor == .person("alex"))
    let runs = try RunBook(try await rig.harness.sink.events(from: 1)).all
    #expect(runs.map(\.trigger) == ["message"])
    #expect(
        runs.first?.input == "alex corrects you (kept in memory): ISSUE-7 is a duplicate of ISSUE-3"
    )
    // The run's instructions carry the new note.
    #expect(started.payload["instructions"]?.stringValue?.contains("ISSUE-3") == true)

    // The same correction again records the message but no second note.
    let again = try await rig.inbox.post(
        "ISSUE-7 is a duplicate of ISSUE-3", from: "alex", to: triage, intent: .correct)
    await rig.scheduler.settle()
    #expect(again.note == nil)
    #expect(try await rig.events("memory.added").count == 1)
    #expect(try await rig.events(InboxEventType.message).count == 2)
}

@Test func messagesAreRecordedEvenWithoutAMessageTrigger() async throws {
    let rig = InboxRig()
    try await rig.create([.manual])
    let receipt = try await rig.inbox.post(
        "Take ISSUE-9", from: "alex", to: triage, intent: .handoff)
    #expect(!receipt.triggered)
    #expect(try await rig.events(InboxEventType.message).count == 1)
    #expect(try await rig.events("run.started").isEmpty)
}

@Test func theInboxRefusesStrangersAndEmptyText() async throws {
    let rig = InboxRig()
    try await rig.create()
    await #expect(throws: InboxError.unknownSender("sam")) {
        try await rig.inbox.post("hi", from: "sam", to: triage)
    }
    // An MCP binding is not a person.
    await #expect(throws: InboxError.unknownSender("tracker")) {
        try await rig.inbox.post("hi", from: "tracker", to: triage)
    }
    await #expect(throws: InboxError.emptyText) {
        try await rig.inbox.post("  ", from: "alex", to: triage)
    }
    await #expect(throws: InboxError.unknownSteward(StewardID(unchecked: "st_none"))) {
        try await rig.inbox.post("hi", from: "alex", to: StewardID(unchecked: "st_none"))
    }
    #expect(try await rig.events(InboxEventType.message).isEmpty)
}

@Test func theInboxBookThreadsBothDirections() async throws {
    let rig = InboxRig()
    try await rig.create([.manual])
    _ = try await rig.inbox.post("Is ISSUE-7 a bug?", from: "alex", to: triage)
    let run = RunID(unchecked: "run_01")
    _ = try await rig.harness.sink.append(
        RuntimeEventDraft(
            type: ActionEventType.executed, steward: triage, run: run, actor: .system,
            payload: [
                "action": "reply",
                "output": [
                    "inbox": "alex", "channel": "local", "target": "tracker:ISSUE-7",
                    "params": ["text": "Yes, it crashes on save."],
                ],
            ]))
    let thread = try #require(
        try InboxBook(try await rig.harness.sink.events(from: 1))
            .threads[triage])
    #expect(thread.map(\.direction) == [.inbound, .outbound])
    #expect(thread.map(\.text) == ["Is ISSUE-7 a bug?", "Yes, it crashes on save."])
    #expect(thread[0].intent == .ask)
    #expect(thread[1].run == run)
    #expect(thread[1].action == "reply")
}
