import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

@Test func notesCarryProvenanceNewestFirst() {
    let list = MemoryList.build(events: PreviewFixtures.triage(now: now))
    #expect(list.live.map(\.id) == [PreviewFixtures.correctionNote, PreviewFixtures.stewardNote])
    #expect(list.retracted.isEmpty)
    let fromRun = list.live[1]
    #expect(fromRun.author == FeatureActor(kind: .steward, id: "st_triage"))
    #expect(fromRun.tags == ["routing", "login"])
    let at = fromRun.addedAt.addingTimeInterval(120)
    #expect(
        MemoryText.provenance(fromRun, now: at) == "by st_triage · from run_0001 (ev_6) · 2m ago")
    let fromCase = list.live[0]
    #expect(
        MemoryText.provenance(fromCase, now: fromCase.addedAt)
            == "by local · from case case-0007 · just now")
}

@Test func retractingRecordsTheLocalUserAndMovesTheNote() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let note = PreviewFixtures.stewardNote
    let written = try await workspace.record(.retractMemory(note: note, reason: "outdated"))
    #expect(written.map(\.type) == ["memory.retracted"])
    #expect(written[0].actor == .localUser)
    #expect(written[0].steward == PreviewFixtures.steward)
    let list = MemoryList.build(events: await workspace.events())
    #expect(list.live.map(\.id) == [PreviewFixtures.correctionNote])
    let retraction = try #require(list.retracted.first?.retraction)
    #expect(MemoryText.retraction(retraction) == "Retracted by local: outdated")
    await #expect(throws: FeatureWriteError.alreadyRetracted(note)) {
        try await workspace.record(.retractMemory(note: note, reason: ""))
    }
    await #expect(throws: FeatureWriteError.unknownNote("note_nope")) {
        try await workspace.record(.retractMemory(note: "note_nope", reason: ""))
    }
}

@Test func memoryFiltersBySteward() {
    let list = MemoryList.build(events: PreviewFixtures.triage(now: now), steward: "st_other")
    #expect(list.live.isEmpty)
}
