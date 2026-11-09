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
