import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private let steward = StewardID(unchecked: "st_inbox")

private func append(_ workspace: Workspace, _ type: String, _ payload: some Encodable)
    async throws
{
    _ = try await workspace.sink.append(
        RuntimeEventDraft(
            type: type, steward: steward, actor: .localUser,
            payload: try CanonicalJSON.decode(
                JSONValue.self, from: try CanonicalJSON.encode(payload))))
}

/// Proposes a routine version (body in the home's blobs) and returns its version hash.
private func propose(_ opened: Opened, _ body: String, reason: String) async throws -> String {
    let source = try RoutineSource(name: "tag-billing", language: .sh, content: body)
    let payload = try source.propose(into: BlobStore(home: opened.home.url), reason: reason)
    try await append(opened.workspace, RoutineEventType.proposed, payload)
    return source.version
}

@Test func routinesShowVersionsBodiesGateStatusAndHistory() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let first = try await propose(opened, "echo billing\n", reason: "label billing mail")
    try await append(
        workspace, RoutineEventType.promoted,
        RoutinePromotedPayload(name: "tag-billing", version: first))
    let second = try await propose(opened, "echo billing-v2\n", reason: "new label")

    let routines = try await workspace.routines(steward: "st_inbox")
    #expect(routines.map(\.name) == ["tag-billing"])
    #expect(routines.first?.liveVersion == first)
    #expect(routines.first?.latestVersion == second)
    #expect(routines.first?.pending == 1)

    let live = try #require(
        try await workspace.routine(steward: "st_inbox", name: "tag-billing", version: first))
    #expect(live.content == "echo billing\n")
    #expect(live.gate == .live)
    #expect(live.language == "sh")
    #expect(live.reason == "label billing mail")
    let pending = try await workspace.routine(
        steward: "st_inbox", name: "tag-billing", version: second)
    #expect(pending?.gate == .pending)
    #expect(
        try await workspace.routineContent(
            steward: "st_inbox", name: "tag-billing", version: second)
            == "echo billing-v2\n")
    #expect(
        try await workspace.routine(steward: "st_inbox", name: "tag-billing", version: "missing")
            == nil)

    let history = try await workspace.routineHistory(steward: "st_inbox", name: "tag-billing")
    #expect(history.map(\.kind) == ["proposed", "promoted", "proposed"])
    #expect(history.map(\.version) == [first, first, second])
    #expect(history.map(\.seq) == history.map(\.seq).sorted())

    await #expect(throws: WorkspaceError.notFound("st_missing")) {
        try await workspace.routines(steward: "st_missing")
    }
}

@Test func aMissingRoutineBlobLeavesTheBodyEmpty() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let source = try RoutineSource(name: "tag-billing", language: .sh, content: "echo x\n")
    try await append(
        workspace, RoutineEventType.proposed, RoutineProposedPayload(source: source))

    let detail = try await workspace.routine(
        steward: "st_inbox", name: "tag-billing", version: source.version)
    #expect(detail != nil)
    #expect(detail?.content == nil)
}

@Test func memoryListsLiveAndRetractedNotes() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let author = MemoryAuthor(kind: .human, id: "local")
    let ids = Ambient.fixed()
    let keptID = ids.newID(NoteID.self)
    let caseID = try #require(CaseID(rawValue: "case-1"))
    let kept = try MemoryNote(
        id: keptID, text: "MSG-9 style mail is billing", tags: ["billing"],
        provenance: MemoryProvenance(caseID: caseID, author: author))
    let dropped = try MemoryNote(
        id: ids.newID(NoteID.self), text: "stale",
        provenance: MemoryProvenance(author: author))
    try await append(workspace, MemoryEventType.added, MemoryAddedPayload(note: kept))
    try await append(workspace, MemoryEventType.added, MemoryAddedPayload(note: dropped))
    try await append(
        workspace, MemoryEventType.retracted, MemoryRetractedPayload(note: dropped.id))

    let live = try await workspace.memory(steward: "st_inbox")
    #expect(live.map(\.id) == [keptID.rawValue])
    #expect(live.first?.author == "human:local")
    #expect(live.first?.caseID == "case-1")
    #expect(live.first?.tags == ["billing"])
    let all = try await workspace.memory(steward: "st_inbox", includeRetracted: true)
    #expect(all.map(\.retracted) == [false, true])
}

@Test func caseExpectedReadsACasebookVersion() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let imported = try await workspace.importCasebook(
        steward: "st_inbox", data: try casebookLines(), name: "inbox")

    let expected = try #require(
        try await workspace.caseExpected(casebook: imported.version, case: "case-1"))
    let value = try CanonicalJSON.decode(JSONValue.self, from: expected)
    #expect(value["decisions"] != nil)
    #expect(try await workspace.caseExpected(casebook: imported.version, case: "case-99") == nil)
    #expect(try await workspace.caseExpected(casebook: "missing", case: "case-1") == nil)
}

@Test func knowledgeViewExplainsNotesAndRoutineVersions() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let ids = Ambient.fixed()
    let local = MemoryAuthor(kind: .human, id: "local")
    let corrected = try MemoryNote(
        id: ids.newID(NoteID.self), text: "Card updates are billing",
        provenance: MemoryProvenance(
            caseID: try #require(CaseID(rawValue: "case-3")), author: local))
    let typed = try MemoryNote(
        id: ids.newID(NoteID.self), text: "Answer in English",
        provenance: MemoryProvenance(author: MemoryAuthor(kind: .human, id: "alex")))
    try await append(workspace, MemoryEventType.added, MemoryAddedPayload(note: corrected))
    try await append(workspace, MemoryEventType.added, MemoryAddedPayload(note: typed))
    let first = try await propose(opened, "echo billing\n", reason: "label billing mail")
    try await append(
        workspace, RoutineEventType.promoted,
        RoutinePromotedPayload(name: "tag-billing", version: first))
    let second = try await propose(opened, "echo billing-v2\n", reason: "new label")

    let view = try await workspace.knowledge(steward: "st_inbox")

    #expect(view.notes.map(\.note.text) == ["Answer in English", "Card updates are billing"])
    #expect(
        view.notes.map(\.provenance) == ["Added by alex.", "From your correction to case case-3."])
    #expect(view.notes.allSatisfy { !$0.time.absolute.isEmpty })
    let routine = try #require(view.routines.first)
    #expect(routine.routine.name == "tag-billing")
    #expect(routine.versions.map(\.version) == [second, first])
    #expect(routine.versions.map(\.approval) == ["Waiting for approval", "Live"])
}

@Test func retractingANoteRemovesItFromKnowledgeAndRecall() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let ids = Ambient.fixed()
    let note = try MemoryNote(
        id: ids.newID(NoteID.self), text: "Card updates are billing",
        provenance: MemoryProvenance(author: MemoryAuthor(kind: .human, id: "local")))
    let kept = try MemoryNote(
        id: ids.newID(NoteID.self), text: "Answer in English",
        provenance: MemoryProvenance(author: MemoryAuthor(kind: .human, id: "local")))
    try await append(workspace, MemoryEventType.added, MemoryAddedPayload(note: note))
    try await append(workspace, MemoryEventType.added, MemoryAddedPayload(note: kept))

    let retracted = try await workspace.retract(
        memory: note.id.rawValue, reason: "Wrong team", by: "person:alex")

    #expect(retracted.retracted)
    #expect(retracted.text == "Card updates are billing")
    #expect(try await workspace.memory(steward: "st_inbox").map(\.text) == ["Answer in English"])
    let knowledge = try await workspace.knowledge(steward: "st_inbox")
    #expect(knowledge.notes.map(\.note.text) == ["Answer in English"])
    let recall = try MemoryProjection(ledger: try opened.workspace.reader.events())
    #expect(recall.liveNotes(steward: steward).map(\.note.id) == [kept.id])
    let event = try #require(try await workspace.ledger().last)
    #expect(event.type == "memory.retracted")
    #expect(event.actorKind == "human" && event.actorID == "person:alex")
    #expect(event.payload.contains("Wrong team"))
    await #expect(throws: WorkspaceError.self) {
        try await workspace.retract(memory: note.id.rawValue)
    }
    await #expect(throws: WorkspaceError.notFound("note_missing")) {
        try await workspace.retract(memory: "note_missing")
    }
}

@Test func sharedNotesAndPreferencesReachEveryStewardsRuns() async throws {
    let opened = try await Opened([
        FakeScript.Run(result: liveResult), FakeScript.Run(result: liveResult),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let own = try await workspace.remember("MSG-9 style mail is billing", steward: "st_inbox")
    let shared = try await workspace.remember("Our business day ends at 17:00 UTC.")
    let preference = try await workspace.remember(
        "Keeps replies under five sentences.", about: "person:alex", by: "person:alex")
    #expect(!own.shared && shared.shared && preference.shared)
    #expect(preference.about == "person:alex")
    #expect(preference.author == "human:person:alex")

    #expect(try await workspace.memory(steward: "st_inbox").map(\.id) == [own.id])
    #expect(try await workspace.sharedMemory().map(\.id) == [shared.id, preference.id])
    #expect(try await workspace.preferences(person: "person:alex").map(\.id) == [preference.id])
    let knowledge = try await workspace.knowledge(steward: "st_inbox")
    #expect(knowledge.shared.map(\.note.id) == [preference.id, shared.id])
    #expect(
        knowledge.shared.map(\.provenance) == [
            "Alex's preference, added by Alex for every steward.",
            "Shared with every steward by you.",
        ])

    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let started = try #require(
        try await workspace.ledger().first { $0.type == "run.started" && $0.run == run.id })
    for id in [own.id, shared.id] { #expect(started.payload.contains(id)) }
    // A preference reaches the runs that act for its person, not every run (runtime 0061).
    #expect(!started.payload.contains(preference.id))
    let forAlex = try await workspace.startRun(
        steward: "st_inbox", input: "Reply to person:alex about MSG-9")
    let alexStart = try #require(
        try await workspace.ledger().first { $0.type == "run.started" && $0.run == forAlex.id })
    #expect(alexStart.payload.contains(preference.id))
    #expect(try await workspace.personMemory(person: "alex").map(\.id) == [preference.id])

    try await workspace.retract(memory: shared.id)
    #expect(try await workspace.sharedMemory().map(\.id) == [preference.id])
    await #expect(throws: WorkspaceError.self) {
        try await workspace.remember("x", about: "alex")
    }
    await #expect(throws: WorkspaceError.self) { try await workspace.remember("  ") }
}
