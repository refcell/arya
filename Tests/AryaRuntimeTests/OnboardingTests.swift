import AryaAdapters
import AryaCore
import AryaMemory
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

/// A binding server that answers `directory` and `process` like the convention says.
private struct OrgChart: ToolUpstream {
    var fails = false

    func listTools() async throws -> [JSONValue] { [] }
    func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
        if fails { throw RunError.stewardRetired(triage) }
        let content: JSONValue =
            switch tool {
            case "directory":
                [
                    "people": [
                        [
                            "id": "person:sam", "name": "Sam Lee", "roles": ["lead"],
                            "queues": ["billing"],
                        ],
                        ["id": "person:ana", "name": "Ana Ruiz"],
                    ]
                ]
            default:
                [
                    "queues": [
                        [
                            "id": "billing", "name": "Billing", "owner": "person:sam",
                            "description": "Refunds and invoices.",
                        ]
                    ],
                    "rules": [
                        [
                            "id": "r1", "when": "a message mentions a refund",
                            "then": ["kind": "route", "target": "queue:billing"],
                            "source": "doc:playbook",
                        ]
                    ],
                    "documents": [
                        ["id": "doc:playbook", "title": "Playbook", "text": "Answer within a day."]
                    ],
                ]
            }
        return ["structuredContent": content]
    }
    func close() async {}
}

private func onboardingCharter() -> Charter {
    var charter = triageCharter()
    charter.bindings.append(
        .mcp("org", command: "org-mcp", read: ["directory", "process"], actions: []))
    return charter
}

@Test func onboardingKeepsPeopleAndProcessAsNotesWithProvenance() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    try await harness.lifecycle.create(onboardingCharter())
    let outcome = try #require(
        try await harness.loop.onboard(triage, connect: { _ in OrgChart() }))
    #expect(
        outcome.completed
            == OnboardCompleted(
                sources: ["org"], notes: 5, people: 2, queues: 1, rules: 1, documents: 1))
    let events = try await harness.sink.events(from: 1).filter { $0.draft.run == outcome.run }
    #expect(
        events.map(\.type) == [
            "run.started", "onboard.read", "onboard.read", "memory.added", "memory.added",
            "memory.added", "memory.added", "memory.added", "onboard.completed", "run.finished",
        ])
    #expect(events.first?.payload["input"]?["kind"] == "onboard")
    let notes = try events.filter { $0.type == "memory.added" }.map {
        try Payload.decode(MemoryAddedPayload.self, $0.payload).note
    }
    #expect(
        notes.map(\.text).contains(
            "Person: Sam Lee (person:sam), roles lead; handles queues billing."))
    let rule =
        "Routing rule: when a message mentions a refund, route queue:billing;"
        + " written in doc:playbook."
    #expect(notes.map(\.text).contains(rule))
    #expect(notes.allSatisfy { $0.provenance.run == outcome.run })
    #expect(notes.allSatisfy { $0.tags.contains("onboarding") && $0.tags.contains("from:org") })
    // The notes reach the next run's instructions.
    let state = try await harness.loop.start.current(harness.sink)
    #expect(state.memory.memory.liveNotes(steward: triage).count == 5)

    // Onboarding again adds nothing it already knows.
    let again = try #require(try await harness.loop.onboard(triage, connect: { _ in OrgChart() }))
    #expect(again.completed.notes == 0)
    #expect(again.completed.duplicates == 5)
    let latest = try #require(
        try Onboarding.latest(triage, in: try await harness.sink.events(from: 1)))
    #expect(latest.run == again.run)
}

@Test func anUnreadableSourceFailsTheOnboardRun() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    try await harness.lifecycle.create(onboardingCharter())
    let outcome = try #require(
        try await harness.loop.onboard(triage, connect: { _ in OrgChart(fails: true) }))
    #expect(outcome.completed.failed == 2)
    #expect(outcome.completed.sources.isEmpty)
    let types = try await harness.sink.events(from: 1).filter { $0.draft.run == outcome.run }
        .map(\.type)
    #expect(types.last == "run.failed")
    #expect(!types.contains("memory.added"))
}

@Test func aNewStewardOnboardsBeforeItsFirstLiveRunOnly() async throws {
    let harness = RunHarness(
        script: FakeScript(
            runs: [FakeScript.Run(result: triageResult), FakeScript.Run(result: triageResult)]),
        connect: { _ in OrgChart() })
    _ = try await harness.start(charter: onboardingCharter())
    _ = try await harness.start(charter: onboardingCharter())
    let events = try await harness.sink.events(from: 1)
    #expect(events.filter { $0.type == "onboard.completed" }.count == 1)
    let first = try #require(events.firstIndex { $0.type == "onboard.completed" })
    let live = try #require(
        events.firstIndex { $0.type == "run.started" && $0.payload["input"]?["kind"] == "manual" })
    #expect(first < live)
    // The first live run already recalls what onboarding learned.
    let instructions = events[live].payload["instructions"]?.stringValue ?? ""
    #expect(instructions.contains("Sam Lee"))
}

@Test func aStewardWithoutOnboardingSourcesNeverOnboards() async throws {
    let harness = RunHarness(
        script: FakeScript(runs: [FakeScript.Run(result: triageResult)]),
        connect: { _ in OrgChart() })
    _ = try await harness.start()
    #expect(try await harness.sink.events(from: 1).allSatisfy { !$0.type.hasPrefix("onboard.") })
    #expect(try await harness.loop.onboard(triage, connect: { _ in OrgChart() }) == nil)
}

/// A `history` binding with `count` past tickets, paged by offset cursor.
private struct TicketHistory: ToolUpstream {
    var count: Int
    func listTools() async throws -> [JSONValue] { [] }
    func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
        let all = (0..<count).map { i in
            let billing = i % 3 != 2
            return HistoryItem(
                id: "T-\(i)", at: String(format: "2026-09-%02dT10:00:00Z", 1 + i % 28),
                input: "New ticket T-\(i)",
                actions: [
                    HistoryAction(
                        kind: "route", target: billing ? "queue:billing" : "queue:help",
                        by: billing ? "person:sam" : "person:ana")
                ],
                choice: billing ? "billing" : "how-to",
                outcome: HistoryOutcome(
                    status: i % 5 == 4 ? "reopened" : "resolved",
                    note: billing ? "Refunded the duplicate charge." : nil))
        }
        let params = try CanonicalJSON.decode(
            HistoryListParams.self, from: try CanonicalJSON.encode(arguments))
        let page = BindingHistory.page(all, params)
        return [
            "structuredContent": try CanonicalJSON.decode(
                JSONValue.self, from: try CanonicalJSON.encode(page))
        ]
    }
    func close() async {}
}

@Test func onboardingSummarizesPastRecordsIntoCappedNotes() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    var charter = triageCharter()
    charter.bindings.append(.mcp("desk", command: "desk-mcp", read: ["history"], actions: []))
    try await harness.lifecycle.create(charter)
    let outcome = try #require(
        try await harness.loop.onboard(triage, connect: { _ in TicketHistory(count: 700) }))
    // The cap bounds what one onboarding reads.
    #expect(outcome.completed.records == Onboarding.historyCap)
    let notes = try await harness.sink.events(from: 1)
        .filter { $0.type == "memory.added" && $0.draft.run == outcome.run }
        .map { try Payload.decode(MemoryAddedPayload.self, $0.payload).note }
    let texts = notes.map(\.text)
    #expect(texts.contains { $0.hasPrefix("Who handles what: person:sam acted on 334 of 500") })
    #expect(texts.contains { $0.contains("mostly route queue:billing (334)") })
    #expect(
        texts.contains {
            $0.hasPrefix("Routing pattern: 334 of 500")
                && $0.contains("billing, usually route queue:billing first")
        })
    #expect(
        texts.contains {
            $0.hasPrefix("Outcomes: of 500 past records")
                && $0.contains("400 resolved and 100 reopened")
        })
    #expect(
        texts.contains {
            $0.contains("Common resolution") && $0.hasSuffix("Refunded the duplicate charge.")
        })
    #expect(notes.allSatisfy { $0.tags.contains("history") && $0.tags.contains("from:desk") })
    #expect(notes.allSatisfy { $0.provenance.run == outcome.run })
    let sam = try #require(notes.first { $0.text.contains("person:sam acted") })
    #expect(sam.tags.contains("person:sam"))
    // A second onboarding adds no duplicates.
    let again = try #require(
        try await harness.loop.onboard(triage, connect: { _ in TicketHistory(count: 700) }))
    #expect(again.completed.notes == 0)
}
