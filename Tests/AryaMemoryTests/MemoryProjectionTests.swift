import Foundation
import Testing

@testable import AryaMemory

@Suite struct MemoryProjectionTests {
    @Test func projectsLiveNotesPerSteward() throws {
        let events = [
            try addedEvent(seq: 1, note: makeNote("mem_1", "first")),
            MemoryEventRecord(
                seq: 2, id: "ev_2", steward: "st_triage", type: "run.started",
                payload: Data("{}".utf8)),
            try addedEvent(seq: 3, steward: "st_inbox", note: makeNote("mem_2", "other")),
            try addedEvent(seq: 4, note: makeNote("mem_3", "third")),
            try retractedEvent(seq: 5, note: "mem_1"),
        ]
        let projection = try MemoryProjection(events: events)
        #expect(projection.liveNotes(steward: "st_triage").map(\.note.id) == ["mem_3"])
        #expect(projection.liveNotes(steward: "st_inbox").map(\.note.id) == ["mem_2"])
        #expect(projection.stewards == ["st_inbox", "st_triage"])
        #expect(projection.lastSeq == 5)
        #expect(projection.note(steward: "st_triage", id: "mem_3")?.seq == 4)
    }

    @Test func retractedNotesStayRetractedAndDuplicatesAreIgnored() throws {
        let events = [
            try addedEvent(seq: 1, note: makeNote("mem_1", "first")),
            try addedEvent(seq: 2, note: makeNote("mem_1", "again")),
            try retractedEvent(seq: 3, note: "mem_1"),
            try addedEvent(seq: 4, note: makeNote("mem_1", "revived?")),
            try retractedEvent(seq: 5, note: "mem_unknown"),
        ]
        let projection = try MemoryProjection(events: events)
        #expect(projection.liveNotes(steward: "st_triage").isEmpty)
    }

    @Test func incrementalEqualsFromScratch() throws {
        let events = [
            try addedEvent(seq: 1, note: makeNote("mem_1", "a")),
            try addedEvent(seq: 2, note: makeNote("mem_2", "b")),
            try retractedEvent(seq: 3, note: "mem_1"),
        ]
        var incremental = try MemoryProjection(events: events.prefix(1))
        for event in events.dropFirst() { try incremental.apply(event) }
        #expect(incremental == (try MemoryProjection(events: events)))
    }

    @Test func rejectsBadEvents() throws {
        var projection = MemoryProjection()
        let noSteward = MemoryEventRecord(
            seq: 1, id: "ev_1", steward: nil, type: MemoryEventType.added,
            payload: Data("{}".utf8))
        #expect(throws: MemoryProjectionError.missingSteward(seq: 1)) {
            try projection.apply(noSteward)
        }
        let bad = MemoryEventRecord(
            seq: 2, id: "ev_2", steward: "st_triage", type: MemoryEventType.added,
            payload: Data("{}".utf8))
        #expect(throws: MemoryProjectionError.invalidPayload(seq: 2, type: "memory.added")) {
            try projection.apply(bad)
        }
    }
}
