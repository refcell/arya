import AryaCore
import Testing

@testable import AryaRuntime

private let steward = StewardID(unchecked: "st_triage")
private let run = RunID(unchecked: "run_000001")
private let label = ProposedAction(
    id: "a1", kind: "label", binding: "tracker", target: "tracker:ISSUE-7",
    params: ["label": "bug"], rationale: "Login timeouts are bugs.")

private func makeQueue() -> (ApprovalQueue, MemoryEventSink) {
    let ambient = Ambient.fixed()
    let sink = MemoryEventSink(ambient: ambient)
    return (ApprovalQueue(sink: sink, ambient: ambient), sink)
}

@Test func requestThenGrantRecordsTheDecidingPerson() async throws {
    let (queue, sink) = makeQueue()
    let requested = try await queue.request(.action(label), steward: steward, run: run)
    #expect(requested.status == .pending)
    #expect(try await queue.book().pending.map(\.id) == [requested.id])

    let alex = RuntimeActor.person("person:alex")
    let granted = try await queue.grant(requested.id, by: alex, note: "fine")
    #expect(granted.status == .granted)
    #expect(granted.decidedBy == alex)
    #expect(granted.note == "fine")
    #expect(try await queue.book().pending.isEmpty)

    let events = try await sink.events(from: 1)
    #expect(events.map(\.type) == ["approval.requested", "approval.granted"])
    #expect(events[0].draft.actor == .steward(steward))
    #expect(events[1].draft.actor == alex)
    #expect(events[1].draft.run == run)
}

@Test func denyAndDoubleDecisionIsRefused() async throws {
    let (queue, _) = makeQueue()
    let record = try await queue.request(.action(label), steward: steward, run: run)
    let denied = try await queue.deny(record.id, by: .localUser)
    #expect(denied.status == .denied)
    await #expect(throws: ApprovalError.alreadyDecided(record.id, .denied)) {
        try await queue.grant(record.id, by: .localUser)
    }
}

@Test func unknownApprovalIsNotFound() async throws {
    let (queue, _) = makeQueue()
    let missing = ApprovalID(unchecked: "ap_missing")
    await #expect(throws: ApprovalError.notFound(missing)) {
        try await queue.grant(missing, by: .localUser)
    }
}

@Test func expiryOnlyTouchesDueApprovals() async throws {
    let (queue, sink) = makeQueue()
    let due = try await queue.request(
        .question("Assign to whom?"), steward: steward, run: run, to: "person:alex",
        expiresAt: Timestamp(millis: 1_000))
    let later = try await queue.request(
        .action(label), steward: steward, run: run, expiresAt: Timestamp(millis: 9_000))
    let never = try await queue.request(.action(label), steward: steward, run: run)

    let expired = try await queue.expireDue(now: Timestamp(millis: 5_000))
    #expect(expired.map(\.id) == [due.id])
    #expect(expired[0].status == .expired)
    #expect(expired[0].decidedBy == nil)
    #expect(try await queue.book().pending.map(\.id) == [later.id, never.id])
    #expect(try await sink.events(from: 1).last?.draft.actor == .system)
}

@Test func bookRebuiltFromEventsMatchesLiveState() async throws {
    let (queue, sink) = makeQueue()
    let first = try await queue.request(.action(label), steward: steward, run: run)
    let second = try await queue.request(.question("Which team?"), steward: steward, run: run)
    try await queue.grant(first.id, by: .localUser)

    let rebuilt = try ApprovalBook(try await sink.events(from: 1))
    #expect(rebuilt.all.map(\.status) == [.granted, .pending])
    #expect(rebuilt.records[second.id]?.subject == .question("Which team?"))
    #expect(rebuilt.records[first.id]?.subject == .action(label))
}

@Test func laterDecisionAfterFirstIsIgnoredByProjection() throws {
    let id = ApprovalID(unchecked: "ap_1")
    func event(_ seq: Int, _ type: String, _ payload: JSONValue, _ actor: RuntimeActor)
        -> RuntimeEvent
    {
        RuntimeEvent(
            seq: seq, id: EventID(unchecked: "ev_\(seq)"), at: Timestamp(millis: Int64(seq)),
            draft: RuntimeEventDraft(
                type: type, steward: steward, run: run, actor: actor, payload: payload))
    }
    let book = try ApprovalBook([
        event(
            1, "approval.requested",
            [
                "approval": "ap_1", "kind": "question",
                "question": "Ok?", "to": "local",
            ], .steward(steward)),
        event(2, "approval.granted", ["approval": "ap_1"], .person("person:alex")),
        event(3, "approval.denied", ["approval": "ap_1"], .localUser),
    ])
    #expect(book.records[id]?.status == .granted)
    #expect(book.records[id]?.decidedBy == .person("person:alex"))
}
