import AryaCore
import AryaLedger
import Foundation
import Testing

@testable import AryaMemory

@Suite struct MemoryIntakeTests {
    @Test func turnsProposedNotesIntoStewardDrafts() throws {
        let live = try MemoryProjection(events: [
            addedEvent(seq: 1, note: makeNote("mem_1", "Auth issues go to the auth queue."))
        ])
        let intake = try MemoryIntake.notes(
            [
                ProposedNote(text: "SSO errors are auth bugs.", tags: ["Auth"]),
                ProposedNote(text: "  "),
                ProposedNote(text: "Auth issues go to the auth queue."),
                ProposedNote(text: "SSO errors are auth bugs. "),
                ProposedNote(text: "Weekly digest goes out on Monday."),
            ],
            steward: "st_triage", run: "run_9", resultEvent: "ev_40", live: live,
            ambient: .fixed())
        #expect(
            intake.accepted.map(\.text) == [
                "SSO errors are auth bugs.", "Weekly digest goes out on Monday.",
            ])
        #expect(intake.rejected.map(\.index) == [1])
        #expect(intake.duplicates == [2, 3])
        let first = try #require(intake.accepted.first)
        #expect(first.tags == ["auth"])
        #expect(
            first.provenance
                == MemoryProvenance(
                    run: "run_9", event: "ev_40",
                    author: MemoryAuthor(kind: .steward, id: "st_triage")))
        #expect(intake.drafts.map(\.actor) == [.steward("st_triage"), .steward("st_triage")])
        #expect(intake.drafts.map(\.run) == ["run_9", "run_9"])
    }

    @Test func noteIdsComeFromTheAmbient() throws {
        func ids() throws -> [NoteID] {
            try MemoryIntake.notes(
                [ProposedNote(text: "a"), ProposedNote(text: "b")], steward: "st_triage",
                run: "run_1", live: MemoryProjection(), ambient: .fixed(seed: 7)
            ).accepted.map(\.id)
        }
        let first = try ids()
        #expect(first == (try ids()))
        #expect(Set(first).count == 2)
        #expect(first.allSatisfy { $0.rawValue.hasPrefix("mem_") })
    }
}

@Suite struct RunPreparationTests {
    func projections() throws -> (MemoryProjection, RoutineLibrary) {
        let correction = try MemoryCorrections.note(
            id: "mem_9", text: "Duplicates are not bugs.", person: "person:alex",
            caseID: "case-0007", correctionEvent: "ev_9")
        let memory = try MemoryProjection(events: [
            addedEvent(seq: 1, note: makeNote("mem_1", "Login issues are auth.", tags: ["login"])),
            addedEvent(
                seq: 2,
                note: makeNote(
                    "mem_2", "Billing goes to finance.",
                    tags: ["billing"])),
            addedEvent(seq: 3, note: correction),
            addedEvent(seq: 4, note: makeNote("mem_4", "Be brief.")),
        ])
        let source = try RoutineSource(name: "label-issue", language: .sh, content: labelV1)
        let routines = try RoutineLibrary(events: [
            routineEvent(
                seq: 5, type: RoutineEventType.proposed,
                RoutineProposedPayload(source: source)),
            routineEvent(
                seq: 6, type: RoutineEventType.promoted,
                RoutinePromotedPayload(name: source.name, version: source.version)),
        ])
        return (memory, routines)
    }

    @Test func queryPicksTagsMentionedInTheInput() {
        let query = MemoryQuery.forRun(
            inputText: "New issue: Login page times out (see billing.)", caseID: "case-1",
            knownTags: ["login", "billing", "mobile", "case:case-1"])
        #expect(query.tags == ["billing", "case:case-1", "login"])
        #expect(MemoryQuery.words("a-b c:d e.f. g_h") == ["a-b", "c:d", "e.f", "g_h"])
    }

    @Test func contextMatchesGolden() throws {
        let (memory, routines) = try projections()
        let context = RunPreparation.context(
            steward: "st_triage", inputText: "New issue: login page times out",
            caseID: "case-0007", memory: memory, routines: routines, maxNotes: 3)
        #expect(context.snapshot.notes == ["mem_9", "mem_1", "mem_4"])
        #expect(
            context.routineVersions == [
                "label-issue": RoutineNaming.version(
                    of: Data(labelV1.utf8))
            ])
        #expect(context.routines.map(\.name) == ["label-issue"])
        #expect(
            try CanonicalJSON.string(context.snapshotJSON)
                == (try fixture("memory.snapshot.run.json")))
        let decoded = try CanonicalJSON.decode(
            MemorySnapshot.self, from: CanonicalJSON.encode(context.snapshotJSON))
        #expect(decoded == context.snapshot)
    }

    @Test func listsRetractedNotesForListings() throws {
        let projection = try MemoryProjection(events: [
            addedEvent(seq: 1, note: makeNote("mem_1", "a")),
            addedEvent(seq: 2, note: makeNote("mem_2", "b")),
            retractedEvent(seq: 3, note: "mem_1"),
        ])
        let all = projection.allNotes(steward: "st_triage")
        #expect(all.map(\.note.note.id) == ["mem_1", "mem_2"])
        #expect(all.map(\.retracted) == [true, false])
    }
}
