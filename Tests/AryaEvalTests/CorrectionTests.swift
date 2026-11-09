import AryaCore
import AryaMemory
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

private let steward = StewardID(unchecked: "st_triage")
private let case1 = CaseID(rawValue: "case-0001")!

@Test func correctionRecordsEventNoteAndNewCasebook() async throws {
    let book = try Casebook.parse(name: "triage", data: try fixture("triage.jsonl"))
    let sink = MemoryEventSink(ambient: .fixed())
    let corrector = Corrector(sink: sink, blobs: MemoryBlobs(), ambient: .fixed(seed: 7))
    let correction = CaseCorrection(
        caseID: case1, text: "Timeouts on login are incidents, not bugs.",
        expected: ["decisions": [["choice": "incident"]]],
        rehearsal: RehearsalID(unchecked: "reh_1"))
    let outcome = try await corrector.correct(
        correction, in: book, steward: steward, person: "person:alex")

    let events = try await sink.events(from: 1)
    #expect(events.map(\.type) == ["case.corrected", "memory.added", "casebook.imported"])
    #expect(events.allSatisfy { $0.draft.actor == .person("person:alex") })
    #expect(events[0].payload["case"] == "case-0001")
    #expect(events[0].payload["casebook"] == .string(book.version))
    #expect(outcome.note.provenance.event == events[0].id)
    #expect(outcome.note.isCorrection)
    #expect(outcome.note.tags.contains("case:case-0001"))
    let corrected = try #require(outcome.casebook)
    #expect(corrected.version != book.version)
    #expect(events[2].payload["correctedFrom"] == .string(book.version))
    #expect(events[2].payload["version"] == .string(corrected.version))
    #expect(corrected.cases[0].expected["decisions"]?[0]?["choice"] == "incident")
    #expect(corrected.cases[1] == book.cases[1])
}

@Test func noteOnlyCorrectionKeepsTheCasebook() async throws {
    let book = try Casebook.parse(name: "triage", data: try fixture("triage.jsonl"))
    let sink = MemoryEventSink(ambient: .fixed())
    let outcome = try await Corrector(sink: sink, blobs: MemoryBlobs(), ambient: .fixed())
        .correct(
            CaseCorrection(caseID: case1, text: "Check the status page first."), in: book,
            steward: steward, person: "local")
    #expect(outcome.casebook == nil)
    #expect(try await sink.events(from: 1).map(\.type) == ["case.corrected", "memory.added"])
}

@Test func correctingAnUnknownCaseFails() async throws {
    let book = try Casebook.parse(name: "triage", data: try fixture("triage.jsonl"))
    let sink = MemoryEventSink(ambient: .fixed())
    let missing = CaseID(rawValue: "case-9")!
    await #expect(throws: EvalError.unknownCase(missing)) {
        try await Corrector(sink: sink, blobs: MemoryBlobs(), ambient: .fixed())
            .correct(
                CaseCorrection(caseID: missing, text: "x"), in: book, steward: steward,
                person: "local")
    }
    #expect(try await sink.events(from: 1).isEmpty)
}

@Test func markReadyRecordsTheReviewedRehearsal() async throws {
    let sink = MemoryEventSink(ambient: .fixed())
    let request = RehearsalRequest(steward: steward, charterVersion: 3, casebookVersion: "abc")
    let rehearsal = RehearsalResult(
        id: RehearsalID(unchecked: "reh_9"), request: request,
        outcomes: [CaseOutcome(caseID: case1, samples: [CaseScore(value: 1, passed: true)])])
    let event = try await Readiness(sink: sink).markReady(
        steward: steward, charterVersion: 3, reviewed: rehearsal, person: "local")
    #expect(event.type == "steward.ready")
    #expect(event.draft.actor == .localUser)
    #expect(event.payload["rehearsal"] == "reh_9")
    #expect(event.payload["casebook"] == "abc")
    #expect(event.payload["meanScore"] == 1)
    #expect(event.payload["charterVersion"] == 3)
}
