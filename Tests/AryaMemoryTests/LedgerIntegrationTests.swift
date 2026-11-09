import AryaCore
import AryaLedger
import Foundation
import Testing

@testable import AryaMemory

/// Seals drafts into a chained ledger, round-trips each line through `LedgerLine.open`, and
/// returns the events as a reader would see them.
func ledger(_ drafts: [EventDraft]) throws -> [Event] {
    let ambient = Ambient.fixed()
    var prev = Event.genesisHash
    var events: [Event] = []
    for (index, draft) in drafts.enumerated() {
        let sealed = try LedgerLine.seal(
            draft, seq: Int64(index + 1), prev: prev, id: ambient.newID(EventID.self),
            at: ambient.now())
        let reopened = try LedgerLine.open(sealed.line)
        #expect(reopened == sealed.event)
        prev = sealed.event.hash
        events.append(reopened)
    }
    return events
}

@Suite struct LedgerIntegrationTests {
    @Test func memoryProjectsFromSealedLedgerEvents() throws {
        let note = try makeNote("mem_1", "Auth issues go to the auth queue.", tags: ["auth"])
        let correction = try MemoryCorrections.note(
            id: "mem_2", text: "Duplicates are not bugs.", person: "person:alex",
            caseID: "case-0007", correctionEvent: "ev_9")
        let events = try ledger([
            .memoryAdded(note, steward: "st_triage"),
            EventDraft(type: .runStarted, actor: .system, steward: "st_triage"),
            .memoryAdded(correction, steward: "st_triage"),
            .memoryRetracted("mem_1", steward: "st_triage", actor: .local, reason: "stale"),
        ])
        #expect(events[0].actor == .steward("st_triage"))
        #expect(events[0].run == "run_1")
        #expect(events[2].actor == .human("person:alex"))
        #expect(try events[3].payload(as: MemoryRetractedPayload.self).note == "mem_1")
        let projection = try MemoryProjection(ledger: events)
        #expect(projection.liveNotes(steward: "st_triage").map(\.note) == [correction])
        #expect(projection.lastSeq == 4)
    }

    @Test func routineLibraryProjectsFromSealedLedgerEvents() throws {
        let source = try RoutineSource(name: "label-issue", language: .sh, content: labelV1)
        let promoted = RoutinePromotedPayload(name: source.name, version: source.version)
        let events = try ledger([
            EventDraft(
                RoutineProposedPayload(source: source, run: "run_1"),
                actor: .steward("st_triage"), steward: "st_triage", run: "run_1"),
            EventDraft(promoted, actor: .system, steward: "st_triage"),
            EventDraft(type: .metricRecorded, actor: .system, steward: "st_triage"),
        ])
        let library = try RoutineLibrary(ledger: events)
        #expect(
            library.live(steward: "st_triage", name: "label-issue")?.version
                == source.version)
        #expect(library.lastSeq == 3)
    }

    @Test func payloadsDeclareTheLedgerEventTypes() {
        #expect(MemoryAddedPayload.type.rawValue == MemoryEventType.added)
        #expect(MemoryRetractedPayload.type.rawValue == MemoryEventType.retracted)
        #expect(RoutineProposedPayload.type.rawValue == RoutineEventType.proposed)
        #expect(RoutinePromotedPayload.type.rawValue == RoutineEventType.promoted)
        #expect(RoutineRetiredPayload.type.rawValue == RoutineEventType.retired)
    }
}
