import AryaAdapters
import AryaCore
import AryaMemory
import Testing

@testable import AryaRuntime

private let remembering: JSONValue = [
    "summary": "Labeled ISSUE-7.",
    "memories": [
        ["text": "Login timeouts are usually the session cache.", "tags": ["login"]],
        ["text": "   "],
    ],
]

@Test func liveRunRecordsProposedNotesOnce() async throws {
    let harness = RunHarness(
        script: FakeScript(runs: [FakeScript.Run(result: remembering)]))
    let first = try await harness.start()
    var added = try await harness.sink.events(from: 1).filter { $0.type == "memory.added" }
    #expect(added.count == 1)  // the blank note is rejected
    let note = try Payload.decode(MemoryAddedPayload.self, added[0].payload).note
    #expect(note.text == "Login timeouts are usually the session cache.")
    #expect(note.provenance.run == first.run)
    #expect(added[0].draft.actor == .steward(StewardID(unchecked: "st_triage")))
    #expect(added[0].draft.run == first.run)

    // The next run on a matching input sees the note, and the same note is not added twice.
    _ = try await harness.start()
    added = try await harness.sink.events(from: 1).filter { $0.type == "memory.added" }
    #expect(added.count == 1)
    let started = try #require(try await harness.last("run.started"))
    #expect(started.payload["memory"]?["notes"] == [.string(note.id.rawValue)])
    #expect(started.payload["instructions"]?.stringValue?.contains(note.text) == true)
}

@Test func rehearsalRecordsNoNotes() async throws {
    let harness = RunHarness(FakeScript.Run(result: remembering))
    _ = try await harness.start(.rehearsal(CaseContext()))
    #expect(try await harness.last("memory.added") == nil)
}
