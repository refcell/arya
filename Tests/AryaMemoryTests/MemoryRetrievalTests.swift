import Foundation
import Testing

@testable import AryaMemory

@Suite struct MemoryRetrievalTests {
    /// Five notes for `st_triage` and one for another steward, one retracted.
    func projection() throws -> MemoryProjection {
        try MemoryProjection(events: [
            addedEvent(
                seq: 1,
                note: makeNote(
                    "mem_1", "Auth issues go to the auth queue.",
                    tags: ["auth", "routing"])),
            addedEvent(
                seq: 2,
                note: makeNote(
                    "mem_2", "Duplicates are closed by people only.",
                    tags: ["duplicates"])),
            addedEvent(
                seq: 3,
                note: makeNote(
                    "mem_3", "Mobile crashes are high priority.",
                    tags: ["mobile", "priority"])),
            addedEvent(
                seq: 4, steward: "st_inbox",
                note: makeNote(
                    "mem_4", "Not mine.",
                    tags: ["auth"])),
            addedEvent(
                seq: 5,
                note: makeNote(
                    "mem_5", "Login timeouts are auth bugs.",
                    tags: ["auth"])),
            addedEvent(seq: 6, note: makeNote("mem_6", "Weekly digest goes out on Monday.")),
            addedEvent(seq: 7, note: makeNote("mem_7", "Old routing rule.", tags: ["routing"])),
            retractedEvent(seq: 8, note: "mem_7"),
        ])
    }

    @Test func ranksByTagMatchesThenRecency() throws {
        let query = MemoryQuery(tags: ["Auth", "routing"])
        let ids = try projection().retrieve(steward: "st_triage", query: query).map(\.note.id)
        #expect(ids == ["mem_1", "mem_5", "mem_6", "mem_3", "mem_2"])
    }

    @Test func capsByCountAndCharacters() throws {
        let p = try projection()
        let byCount = p.retrieve(steward: "st_triage", query: MemoryQuery(maxNotes: 2))
        #expect(byCount.map(\.note.id) == ["mem_6", "mem_5"])
        // mem_6 (33 bytes) fits; each other note (29 bytes or more) would pass 40.
        let byChars = p.retrieve(steward: "st_triage", query: MemoryQuery(maxCharacters: 40))
        #expect(byChars.map(\.note.id) == ["mem_6"])
        #expect(p.retrieve(steward: "st_triage", query: MemoryQuery(maxNotes: 0)).isEmpty)
    }

    @Test func skipsOversizedNotesButKeepsSmallerOnes() throws {
        let p = try MemoryProjection(events: [
            addedEvent(seq: 1, note: makeNote("mem_1", "short")),
            addedEvent(seq: 2, note: makeNote("mem_2", String(repeating: "x", count: 50))),
        ])
        let notes = p.retrieve(steward: "st_triage", query: MemoryQuery(maxCharacters: 10))
        #expect(notes.map(\.note.id) == ["mem_1"])
    }

    @Test func snapshotAndRenderMatchGolden() throws {
        let p = try projection()
        let query = MemoryQuery(tags: ["auth"], maxNotes: 3)
        let snapshot = p.snapshot(steward: "st_triage", query: query)
        #expect(try encodeJSON(snapshot) == (try fixture("memory.snapshot.json")))
        let rendered = MemoryRetrieval.render(try p.resolve(snapshot, steward: "st_triage"))
        #expect(rendered == (try fixture("memory.rendered.txt")))
        #expect(MemoryRetrieval.render([]) == "")
    }

    @Test func retrievalIsStableAcrossRebuilds() throws {
        let query = MemoryQuery(tags: ["priority", "auth"], maxNotes: 4, maxCharacters: 200)
        let first = try projection().snapshot(steward: "st_triage", query: query)
        let second = try projection().snapshot(steward: "st_triage", query: query)
        #expect(first == second)
    }

    @Test func resolvesRetractedNotesButNotUnknownOnes() throws {
        let p = try projection()
        let notes = try p.resolve(MemorySnapshot(notes: ["mem_7", "mem_1"]), steward: "st_triage")
        #expect(notes.map(\.note.id) == ["mem_7", "mem_1"])
        #expect(throws: MemorySnapshotError.unknownNote("mem_4")) {
            try p.resolve(MemorySnapshot(notes: ["mem_4"]), steward: "st_triage")
        }
    }
}
