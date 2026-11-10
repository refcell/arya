import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private let childAnswer: JSONValue = [
    "summary": "Drafted the reply.",
    "actions": [["id": "c1a", "kind": "label", "binding": "tracker", "target": "tracker:ISSUE-7"]],
]

private func delegatingScript(childSteps: [FakeScript.Step] = []) -> FakeScript {
    FakeScript(runs: [
        FakeScript.Run(
            input: "Draft the reply", steps: childSteps, result: childAnswer),
        FakeScript.Run(
            steps: [.delegate(id: "c1", title: "Draft the reply", input: "Draft the reply")],
            result: triageResult),
    ])
}

private func payload(_ event: RuntimeEvent, _ key: String) -> JSONValue? {
    event.payload.objectValue?[key]
}

@Test func anInRunDelegationRunsAChildThatOnlyProposesAndAnswersTheParent() async throws {
    let harness = RunHarness(script: delegatingScript())
    let outcome = try await harness.start()
    #expect(outcome.phase == .finished(.completed))
    let events = try await harness.sink.events(from: 1)
    let delegated = try #require(events.first { $0.type == "run.delegated" })
    #expect(delegated.draft.run == outcome.run)
    #expect(payload(delegated, "delegation") == "c1")
    let child = try #require(payload(delegated, "child")?.stringValue)
    let started = try #require(
        events.first { $0.type == "run.started" && $0.draft.run?.rawValue == child })
    #expect(payload(started, "parent")?.stringValue == outcome.run.rawValue)
    #expect(payload(started, "input")?.objectValue?["text"] == "Draft the reply")
    // The child's label only proposes; the parent's own label (rule: auto) executes.
    let childEvents = events.filter { $0.draft.run?.rawValue == child }
    #expect(childEvents.contains { $0.type == "action.proposed" })
    #expect(!childEvents.contains { $0.type == "action.executed" })
    #expect(await harness.executor.requests.map(\.run) == [outcome.run])
    // The adapter heard the child's outcome before finishing.
    let status = events.compactMap { event -> String? in
        guard event.draft.run == outcome.run, event.type == "run.adapter.event",
            let detail = event.payload["message"]?["params"]?["event"]?["detail"]?.stringValue
        else { return nil }
        return detail
    }
    #expect(status.contains { $0.hasPrefix("completed \(child)") })
}

@Test func aChildCannotDelegateAgain() async throws {
    let harness = RunHarness(
        script: delegatingScript(childSteps: [
            .delegate(id: "g1", title: "Go deeper", input: "deeper")
        ]))
    _ = try await harness.start()
    let delegations = try await harness.sink.events(from: 1).filter {
        $0.type == "run.delegated"
    }
    #expect(delegations.count == 2)
    #expect(payload(delegations[1], "delegation") == "g1")
    #expect(payload(delegations[1], "refused") == "depth_limit")
    #expect(payload(delegations[1], "child") == nil)
}

@Test func aReplayAnswersFromTheRecordingWithoutRunningAChild() async throws {
    let harness = RunHarness(script: delegatingScript())
    var request = RunRequest(
        steward: StewardID(unchecked: "st_triage"),
        input: RunInput(kind: .manual, text: "New issue: login page times out"))
    try await harness.lifecycle.create(triageCharter())
    request.crewPolicy = .skip
    request.replanning = false
    let answer = HostDelegateResult(run: "run_recorded", status: .completed, result: childAnswer)
    request.delegations = ["c1": RecordedDelegation(delegated: nil, answer: answer)]
    let outcome = try await harness.loop.run(request)
    #expect(outcome.phase == .finished(.completed))
    let starts = try await harness.sink.events(from: 1).filter { $0.type == "run.started" }
    #expect(starts.count == 1)
}

@Test func theAnswerFollowsTheChildsEnd() {
    let run = RunID(unchecked: "run_c")
    let failed = RunOutcome(
        run: run, phase: .failed(.timeout), result: nil, disposals: [], leak: false)
    #expect(
        RunEngine.answer(failed)
            == HostDelegateResult(run: "run_c", status: .failed, reason: "timeout"))
    let stopped = RunOutcome(
        run: run, phase: .finished(.stopped), result: nil, disposals: [], leak: false)
    #expect(RunEngine.answer(stopped).status == .stopped)
}
