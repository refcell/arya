import AryaAdapters
import AryaCore
import AryaMemory
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private func peopleCharter() -> Charter {
    var charter = triageCharter()
    charter.bindings += [.person("alex", channel: "local"), .person("sam", channel: "local")]
    return charter
}

private func note(_ text: String, about person: String, _ harness: RunHarness, n: Int)
    async throws
{
    let note = try MemoryNote(
        id: NoteID(unchecked: "mem_p\(n)"), text: text, tags: ["preference", "person:\(person)"],
        provenance: MemoryProvenance(author: MemoryAuthor(kind: .human, id: person)))
    _ = try await harness.sink.append(RuntimeEventDraft(try .memoryAdded(note, steward: triage)))
}

@Test func aRunRecallsTheNotesOfThePeopleItActsFor() async throws {
    let harness = RunHarness(
        script: FakeScript(
            runs: [FakeScript.Run(result: triageResult), FakeScript.Run(result: triageResult)]))
    try await harness.lifecycle.create(peopleCharter())
    try await note("Alex wants short replies.", about: "alex", harness, n: 1)
    try await note("Sam prefers a call for refunds.", about: "sam", harness, n: 2)

    // A message from alex recalls alex's notes, not sam's.
    let message = RunInput(
        kind: .message, text: "alex asks: where is my refund?",
        attachments: [["kind": "inbox", "from": "alex", "intent": "ask"]])
    _ = try await harness.loop.run(RunRequest(steward: triage, input: message))
    // A manual run that names sam recalls sam's notes.
    _ = try await harness.loop.run(.manual(triage, text: "Draft the weekly note for sam."))
    let started = try await harness.sink.events(from: 1).filter { $0.type == "run.started" }
    let first = started[0].payload["instructions"]?.stringValue ?? ""
    let second = started[1].payload["instructions"]?.stringValue ?? ""
    #expect(first.contains("[mem_p1] (person:alex) Alex wants short replies."))
    #expect(!first.contains("Sam prefers"))
    #expect(second.contains("[mem_p2] (person:sam) Sam prefers a call for refunds."))
    #expect(!second.contains("Alex wants"))
    // The snapshot records what the run recalled, for replay.
    #expect(started[0].payload["memory"]?["notes"] == ["mem_p1"])
}

@Test func peopleARunActsForComeFromTheSenderAndTheInput() {
    let charter = peopleCharter()
    let input = RunInput(
        kind: .message, text: "Loop in person:sam and Alex.",
        attachments: [["from": "alex"], ["from": "stranger"]])
    #expect(PersonMemory.people(in: input, charter: charter) == ["alex", "sam"])
    let named = RunInput(kind: .manual, text: "Ask person:lena first.")
    #expect(PersonMemory.people(in: named, charter: charter) == ["lena"])
    #expect(
        PersonMemory.people(in: RunInput(kind: .manual, text: "samples"), charter: charter) == [])
}

@Test func aPersonsCorrectionIsTaggedWithThem() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    try await harness.lifecycle.create(peopleCharter())
    let inbox = Inbox(engine: harness.loop, scheduler: Scheduler(engine: harness.loop))
    _ = try await inbox.record(
        "Refunds over 50 need Sam.", from: "alex", to: triage, intent: .correct)
    let added = try #require(
        try await harness.sink.events(from: 1).first { $0.type == "memory.added" })
    let body = try Payload.decode(MemoryAddedPayload.self, added.payload)
    #expect(body.note.tags == ["correction", "person:alex"])
}
