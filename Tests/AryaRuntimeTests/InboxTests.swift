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

@Test func aReplyProposedOnAPersonBindingIsADeliveryWithoutAnInboxEntry() async throws {
    let rig = InboxRig()
    try await rig.create([.manual])
    _ = try await rig.inbox.post("How many refunds this week?", from: "alex", to: triage)
    let run = RunID(unchecked: "run_02")
    let steps: [(String, JSONValue)] = [
        (
            ActionEventType.proposed,
            [
                "action": [
                    "id": "a1", "kind": "reply", "binding": "alex", "target": "alex",
                    "params": ["text": "Six."],
                ]
            ]
        ),
        (ActionEventType.executed, ["action": "a1", "output": ["dryRun": true]]),
        (
            ActionEventType.proposed,
            ["action": ["id": "a2", "kind": "label", "binding": "tracker", "target": "x"]]
        ),
        (ActionEventType.executed, ["action": "a2", "output": ["dryRun": true]]),
    ]
    for (type, payload) in steps {
        _ = try await rig.harness.sink.append(
            RuntimeEventDraft(
                type: type, steward: triage, run: run, actor: .system,
                payload: payload))
    }
    let events = try await rig.harness.sink.events(from: 1)
    let thread = try #require(try InboxBook(events).threads[triage])
    #expect(thread.map(\.direction) == [.inbound, .outbound])
    #expect(thread.last?.text == "Six.")
    #expect(thread.last?.action == "reply")
    #expect(thread.last?.person == "alex")
    // A charter person who never wrote first is known through `people`.
    let quiet = try InboxBook(Array(events.dropFirst(events.count - 4)), people: [triage: ["alex"]])
    #expect(quiet.threads[triage]?.map(\.text) == ["Six."])
}

/// A relay MCP server: `receive` returns queued messages once; other tools echo their arguments.
private actor RelayServer: ToolUpstream {
    var queued: [JSONValue]
    var calls: [(String, JSONValue)] = []

    init(_ queued: [JSONValue]) { self.queued = queued }

    func listTools() async throws -> [JSONValue] { [] }

    func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
        calls.append((tool, arguments))
        if tool == Inbox.receiveTool {
            defer { queued = [] }
            return ["structuredContent": ["messages": .array(queued)]]
        }
        return ["structuredContent": ["sent": true]]
    }
}

private func relayCharter() -> Charter {
    var charter = triageCharter()
    charter.bindings.append(
        .mcp("mail", command: "mail-server", read: ["receive"], actions: ["reply"]))
    var alex = CharterBinding.person("alex", channel: "alex@example.com")
    alex.via = "mail"
    alex.actions = ["reply"]
    charter.bindings.append(alex)
    charter.triggers = [.manual, .message(from: "alex")]
    return charter
}

@Test func relayMessagesArePostedFromTheMatchingPerson() async throws {
    let rig = InboxRig()
    try await rig.harness.lifecycle.create(relayCharter())
    _ = try await rig.harness.sink.append(
        RuntimeEventDraft(
            type: StewardEventType.ready, steward: triage, actor: .localUser, payload: [:]))
    let server = RelayServer([
        ["from": "alex@example.com", "text": "ISSUE-7 is fixed", "intent": "correct"],
        ["from": "stranger@example.com", "text": "hi"],
        ["from": "alex@example.com", "text": "x", "intent": "shout"],
        ["from": "alex@example.com", "text": "  "],
    ])
    let pull = try await rig.inbox.pull("mail", steward: triage) { _ in server }
    await rig.scheduler.settle()
    #expect(pull.receipts.count == 1)
    #expect(pull.skipped == 3)
    let message = try #require(try await rig.events(InboxEventType.message).first)
    #expect(message.payload["via"] == "mail")
    #expect(message.payload["from"] == "alex")
    #expect(try await rig.events("memory.added").count == 1)
    #expect(try await rig.events("run.started").count == 1)

    await #expect(throws: InboxError.unknownRelay("tracker")) {
        try await rig.inbox.pull("tracker", steward: triage) { _ in server }
    }
}

@Test func repliesToRelayedPeopleGoThroughTheRelay() async throws {
    let charter = try CanonicalJSON.decode(
        Charter.self, from: CanonicalJSON.encode(relayCharter()))  // survives the ledger
    let alex = try #require(charter.binding("alex"))
    #expect(alex.actions == ["reply"])
    let server = RelayServer([])
    let executor = BindingActionExecutor(connectForRun: { binding, _ in
        #expect(binding.id == "mail")
        return server
    })
    let action = ProposedAction(
        id: "a1", kind: "reply", binding: "alex", target: "tracker:ISSUE-7",
        params: ["text": "Thanks, closing it."])
    let outcome = await executor.execute(
        ExecutionRequest(
            steward: triage, run: RunID(unchecked: "run_01"), action: action, binding: alex,
            relay: ActionDispatcher.relay(action, charter)))
    guard case .succeeded(let output) = outcome else {
        Issue.record("expected success, got \(outcome)")
        return
    }
    #expect(output["inbox"] == "alex")
    #expect(output["via"] == "mail")
    #expect(output["result"]?["sent"] == true)
    let calls = await server.calls
    #expect(calls.first?.0 == "reply")
    #expect(calls.first?.1["to"] == "alex@example.com")
    #expect(calls.first?.1["text"] == "Thanks, closing it.")

    let missing = await executor.execute(
        ExecutionRequest(
            steward: triage, run: RunID(unchecked: "run_01"), action: action, binding: alex))
    #expect(missing == .failed(error: "unknown_relay:mail", output: nil))
}

@Test func handlingAMessageReadsOnlyTheEventsSinceTheLastRead() async throws {
    let rig = InboxRig()
    try await rig.create([.manual])
    _ = try await rig.inbox.post("first fact", from: "alex", to: triage, intent: .correct)
    let start = rig.harness.loop.start
    let foldedBefore = await start.folded
    let seqBefore = try await rig.harness.sink.events(from: 1).count
    _ = try await rig.inbox.post("second fact", from: "alex", to: triage, intent: .correct)
    let total = try await rig.harness.sink.events(from: 1).count
    // The second message folds only what was appended since the first one read memory.
    #expect(await start.folded - foldedBefore <= total - seqBefore + 4)
    #expect(await start.folded - foldedBefore < total)
    // A repeated correction is still recognized from the cached memory.
    _ = try await rig.inbox.post("second fact", from: "alex", to: triage, intent: .correct)
    #expect(try await rig.events("memory.added").count == 2)
}
