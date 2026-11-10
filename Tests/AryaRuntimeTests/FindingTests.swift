import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private let findingResult: JSONValue = [
    "summary": "Swept the queue.",
    "findings": [
        [
            "id": "f1", "kind": "Problem", "title": "  Login timeouts tripled this week ",
            "evidence": ["12 issues mention timeouts", " ", "3 last week"],
            "suggestion": [
                "id": "s1", "kind": "label", "binding": "tracker", "target": "tracker:ISSUE-7",
            ],
            "needsPerson": true,
        ],
        ["id": "f2", "kind": "rumor", "title": "Not a kind"],
        ["id": "f3", "kind": "opportunity", "title": "login timeouts TRIPLED this week"],
        ["id": "f4", "kind": "opportunity", "title": "Tag duplicates automatically"],
    ],
]

@Test func aRunRaisesWellFormedFindingsOnce() async throws {
    let harness = RunHarness(FakeScript.Run(result: findingResult))
    let outcome = try await harness.start()
    var book = try FindingBook(try await harness.sink.events(from: 1))
    let open = book.open(triage)
    #expect(open.map(\.raised.finding) == ["f1", "f4"])
    let first = try #require(open.first)
    #expect(first.run == outcome.run)
    #expect(first.raised.kind == "problem")
    #expect(first.title == "Login timeouts tripled this week")
    #expect(first.raised.evidence == ["12 issues mention timeouts", "3 last week"])
    #expect(first.raised.needsPerson)
    #expect(first.raised.suggestion?.kind == "label")
    // The suggestion is shown, never executed.
    #expect(await harness.executor.requests.isEmpty)

    // The next wake repeats itself; nothing new is raised while they are open.
    _ = try await harness.loop.run(
        RunRequest(steward: triage, input: RunInput(kind: .schedule, text: "Scheduled run.")))
    book = try FindingBook(try await harness.sink.events(from: 1))
    #expect(book.all.count == 2)

    try await FindingBook.resolve(
        "f1", run: outcome.run, resolution: "dismissed", by: .localUser, sink: harness.sink)
    book = try FindingBook(try await harness.sink.events(from: 1))
    #expect(book.open(triage).map(\.raised.finding) == ["f4"])
    #expect(book.all.first?.resolvedBy == .localUser)
    await #expect(throws: FindingError.alreadyResolved("f1")) {
        try await FindingBook.resolve(
            "f1", run: outcome.run, resolution: "acted", by: .localUser, sink: harness.sink)
    }
    await #expect(throws: FindingError.invalidResolution("ignored")) {
        try await FindingBook.resolve(
            "f4", run: outcome.run, resolution: "ignored", by: .localUser, sink: harness.sink)
    }
}

@Test func crewChildrenAndRehearsalsRaiseNoFindings() async throws {
    let harness = RunHarness(FakeScript.Run(result: findingResult))
    _ = try await harness.start(.rehearsal(CaseContext()))
    #expect(try FindingBook(try await harness.sink.events(from: 1)).all.isEmpty)
}

@Test func findingsSurviveTheResultRoundTrip() throws {
    let result = RunResult(
        summary: "s", findings: [RunResult.Finding(id: "f", kind: "problem", title: "t")])
    let decoded = try CanonicalJSON.decode(RunResult.self, from: try CanonicalJSON.encode(result))
    #expect(decoded == result)
    let plain = try CanonicalJSON.encode(RunResult(summary: "s"))
    #expect(!String(decoding: plain, as: UTF8.self).contains("findings"))
}
