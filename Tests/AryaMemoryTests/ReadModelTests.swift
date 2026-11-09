import AryaCore
import Foundation
import Testing

@testable import AryaMemory

@Suite struct ReadModelTests {
    @Test func overviewSummarizesEachRoutine() throws {
        let store = InMemoryRoutineBlobStore()
        let v1 = try RoutineSource(name: "label-issue", language: .sh, content: labelV1)
        let v2 = try RoutineSource(name: "label-issue", language: .sh, content: labelV2)
        let note = try RoutineSource(name: "tone", language: .prompt, content: "Be brief.")
        let p = RoutineEventType.self
        let library = try RoutineLibrary(events: [
            routineEvent(seq: 1, type: p.proposed, try v1.propose(into: store)),
            routineEvent(
                seq: 2, type: p.promoted,
                RoutinePromotedPayload(name: v1.name, version: v1.version)),
            routineEvent(
                seq: 3, type: p.proposed,
                try v2.propose(into: store, reason: "Also match SSO.")),
            routineEvent(seq: 4, type: p.proposed, try note.propose(into: store)),
        ])
        let rows = library.overview(steward: "st_triage")
        #expect(rows.map(\.name) == ["label-issue", "tone"])
        #expect(rows[0].liveVersion == v1.version)
        #expect(rows[0].latestVersion == v2.version)
        #expect(rows[0].versions == 2)
        #expect(rows[0].pending == 1)
        #expect(rows[0].summary == "Label new issues by keyword.")
        #expect(rows[0].updatedSeq == 3)
        #expect(rows[1].liveVersion == nil)
        #expect(rows[1].summary == "tone")
        let diff = try library.diff(
            steward: "st_triage", name: "label-issue", from: v1.version, to: v2.version,
            store: store)
        #expect(diff.added == 1 && diff.removed == 1)
        #expect(throws: RoutinePromotionError.self) {
            try library.diff(
                steward: "st_triage", name: "label-issue", from: "x", to: v2.version,
                store: store)
        }
    }

    @Test func provenanceLines() throws {
        let correction = try MemoryCorrections.note(
            id: "mem_2", text: "Duplicates are not bugs.", person: "person:alex",
            caseID: "case-0007", correctionEvent: "ev_9")
        #expect(correction.provenance.line == "human:person:alex · case case-0007 · ev_9")
        let note = try makeNote("mem_1", "a")
        #expect(note.provenance.line == "steward:st_triage · run run_1 · ev_1")
    }
}
