import AryaAdapters
import AryaCore
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private let planned: JSONValue = [
    "summary": "Labeled and commented.",
    "plan": [["id": "p1", "text": "Label ISSUE-7", "status": "in_progress"]],
    "actions": [["id": "a1", "kind": "label", "binding": "tracker", "target": "tracker:ISSUE-7"]],
]

private let revised: JSONValue = [
    "summary": "Labeling is down; asked a person instead.",
    "plan": [
        [
            "id": "p1", "text": "Label ISSUE-7", "status": "blocked",
            "rationale": "the tracker refused the label",
        ],
        ["id": "p2", "text": "Ask alex to label it", "status": "pending"],
    ],
    "actions": [["id": "a2", "kind": "label", "binding": "tracker", "target": "tracker:ISSUE-7"]],
]

@Test func aFailedActionStartsABoundedChainOfReplans() async throws {
    let harness = RunHarness(
        script: FakeScript(runs: [
            FakeScript.Run(input: "New issue: login page times out", result: planned),
            FakeScript.Run(result: revised),  // every re-plan
        ]))
    await harness.executor.setOutcome("label", .failed(error: "tracker: 503", output: nil))
    var charter = triageCharter()
    charter.limits.maxReplans = 2
    let outcome = try await harness.start(charter: charter)

    // The first re-plan revises the plan; its own failure starts the second; the third is refused.
    let first = try #require(outcome.replans.first)
    let second = try #require(first.replans.first)
    #expect(second.replans.isEmpty)
    let book = try RunBook(try await harness.sink.events(from: 1))
    #expect(book.records[first.run]?.trigger == "replan")
    #expect(book.records[first.run]?.parent == outcome.run)
    #expect(book.records[second.run]?.parent == first.run)
    #expect(
        book.records[first.run]?.input.contains("label tracker:ISSUE-7 (a1): failed: tracker: 503")
            == true)

    let refused = try #require(try await harness.last(ReplanRefused.type.rawValue))
    #expect(refused.draft.run == second.run)
    #expect(refused.payload["reason"] == "max_replans: 2")

    let updates = try await harness.sink.events(from: 1).filter { $0.type == PlanEventType.updated }
    #expect(updates.count == 2)  // the original plan, then the revision (the repeat is no change)
    #expect(updates[1].draft.run == first.run)
    #expect(
        updates[1].payload["reason"]?.stringValue
            == "Re-planned after a setback: Labeling is down; asked a person instead.")
    let started = try #require(
        try await harness.sink.events(from: 1).first {
            $0.type == "run.started" && $0.draft.run == first.run
        })
    #expect(started.payload["instructions"]?.stringValue?.contains("[p1] in_progress") == true)
    #expect(started.payload["input"]?["attachments"]?[0]?["kind"] == "failed")
}

@Test func deniedAndExpiredActionsReplan() async throws {
    let harness = RunHarness(script: FakeScript(runs: [FakeScript.Run(result: revised)]))
    try await harness.lifecycle.create(triageCharter())
    let action = ProposedAction(id: "a2", kind: "comment", binding: "tracker")
    let record = try await harness.approvals.request(
        .action(action), steward: triage, run: RunID(unchecked: "run_00"))
    let denied = try await harness.approvals.deny(record.id, by: .person("alex"), note: "too soon")
    let setback = try #require(Setback(denied))
    #expect(setback.kind == .denied)
    #expect(setback.detail == "too soon")
    #expect(setback.approval == record.id)
    let replan = try #require(
        try await harness.loop.replan(
            after: RunID(unchecked: "run_00"), steward: triage, setbacks: [setback]))
    #expect(replan.result?.summary == "Labeling is down; asked a person instead.")

    // Expired, granted-then-failed, and granted-then-done approvals.
    var expired = denied
    expired.status = .expired
    #expect(Setback(expired)?.kind == .expired)
    var granted = denied
    granted.status = .granted
    #expect(Setback(granted, executed: .failed(error: "x", output: nil))?.kind == .failed)
    #expect(Setback(granted, executed: .succeeded(output: [:])) == nil)
}

@Test func rehearsalsChildrenAndInactiveStewardsNeverReplan() async throws {
    let harness = RunHarness(script: FakeScript(runs: [FakeScript.Run(result: planned)]))
    await harness.executor.setOutcome("label", .failed(error: "down", output: nil))
    let rehearsal = try await harness.start(.rehearsal(CaseContext()))
    #expect(rehearsal.replans.isEmpty)

    let paused = RunHarness(script: FakeScript(runs: [FakeScript.Run(result: planned)]))
    await paused.executor.setOutcome("label", .failed(error: "down", output: nil))
    try await paused.lifecycle.create(triageCharter())
    try await paused.lifecycle.pause(triage)
    let setback = Setback(kind: .failed, action: ProposedAction(id: "a1", kind: "label"))
    #expect(
        try await paused.loop.replan(
            after: RunID(unchecked: "run_00"), steward: triage, setbacks: [setback]) == nil)
    #expect(try await paused.last("run.started") == nil)
}
