import Foundation
import Testing

@testable import AryaMemory

@Suite struct MemoryNoteTests {
    @Test func normalizesTextAndTags() throws {
        let note = try makeNote(
            "mem_1", "  Label login bugs as auth.\n",
            tags: [
                " Auth", "bugs", "auth", "",
            ])
        #expect(note.text == "Label login bugs as auth.")
        #expect(note.tags == ["auth", "bugs"])
    }

    @Test func rejectsInvalidNotes() {
        #expect(throws: MemoryNoteError.emptyText) { try makeNote("mem_1", "  \n ") }
        #expect(throws: MemoryNoteError.emptyID) { try makeNote("", "text") }
        let long = String(repeating: "a", count: MemoryNote.maxTextBytes + 1)
        #expect(throws: MemoryNoteError.textTooLong(bytes: long.utf8.count, limit: 4096)) {
            try makeNote("mem_1", long)
        }
    }

    @Test func addedPayloadMatchesGolden() throws {
        let note = try MemoryNote(
            id: "mem_1", text: "Issues mentioning the login page go to the auth queue.",
            tags: ["routing", "auth"],
            provenance: MemoryProvenance(
                run: "run_1", event: "ev_7", author: stewardAuthor()))
        let json = try encodeJSON(MemoryAddedPayload(note: note))
        #expect(json == (try fixture("memory.added.json")))
        let decoded = try JSONDecoder().decode(MemoryAddedPayload.self, from: Data(json.utf8))
        #expect(decoded.note == note)
    }

    @Test func correctionPayloadMatchesGolden() throws {
        let note = try MemoryNote(
            id: "mem_2", text: "Never label a duplicate as a bug.", tags: ["correction"],
            provenance: MemoryProvenance(
                event: "ev_9", caseID: "case-0007",
                author: MemoryAuthor(kind: .human, id: "person:alex")))
        #expect(
            try encodeJSON(MemoryAddedPayload(note: note))
                == (try fixture("memory.added.correction.json")))
    }

    @Test func retractedPayloadMatchesGolden() throws {
        let json = try encodeJSON(MemoryRetractedPayload(note: "mem_1", reason: "outdated"))
        #expect(json == (try fixture("memory.retracted.json")))
    }

    @Test func decodingValidatesNotes() {
        let bad =
            #"{"v":1,"note":{"id":"mem_1","text":" ","tags":[],"#
            + #""provenance":{"author":{"kind":"system","id":"arya"}}}}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MemoryAddedPayload.self, from: Data(bad.utf8))
        }
    }
}
