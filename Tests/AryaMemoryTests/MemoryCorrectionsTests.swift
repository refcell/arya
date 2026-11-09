import Foundation
import Testing

@testable import AryaMemory

@Suite struct MemoryCorrectionsTests {
    func correction() throws -> MemoryNote {
        try MemoryCorrections.note(
            id: "mem_9", text: "A duplicate is never a bug; label it duplicate.",
            person: "person:alex", caseID: "case-0007", correctionEvent: "ev_12",
            run: "run_3", tags: ["Duplicates"])
    }

    @Test func attributesToThePersonAndCase() throws {
        let note = try correction()
        #expect(note.provenance.author == MemoryAuthor(kind: .human, id: "person:alex"))
        #expect(note.provenance.caseID == "case-0007")
        #expect(note.provenance.event == "ev_12")
        #expect(note.provenance.run == "run_3")
        #expect(note.tags == ["case:case-0007", "correction", "duplicates"])
        #expect(note.isCorrection)
        #expect(
            try encodeJSON(MemoryAddedPayload(note: note))
                == (try fixture("memory.added.from-correction.json")))
    }

    @Test func stewardNotesAreNotCorrections() throws {
        let note = try makeNote("mem_1", "A note.", tags: ["correction"])
        #expect(!note.isCorrection)
    }

    @Test func correctionsAreRetrievableByCase() throws {
        let p = try MemoryProjection(events: [
            addedEvent(seq: 1, note: makeNote("mem_1", "Unrelated.")),
            addedEvent(seq: 2, note: correction()),
            addedEvent(seq: 3, note: makeNote("mem_3", "Newer and unrelated.")),
        ])
        #expect(p.corrections(steward: "st_triage").map(\.note.id) == ["mem_9"])
        let query = MemoryQuery(tags: [MemoryCorrections.caseTag("case-0007")], maxNotes: 1)
        #expect(p.retrieve(steward: "st_triage", query: query).map(\.note.id) == ["mem_9"])
    }

    @Test func rejectsEmptyCorrections() {
        #expect(throws: MemoryNoteError.emptyText) {
            try MemoryCorrections.note(
                id: "mem_1", text: " ", person: "local", caseID: "case-1",
                correctionEvent: "ev_1")
        }
    }
}
