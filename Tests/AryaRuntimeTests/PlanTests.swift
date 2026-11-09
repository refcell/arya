import AryaAdapters
import AryaCore
import Testing

@testable import AryaRuntime

private func planning(_ items: JSONValue) -> JSONValue {
    guard case .object(var fields) = triageResult else { return triageResult }
    fields["plan"] = items
    return .object(fields)
}

private let firstPlan: JSONValue = [
    ["id": "p1", "text": "Label new issues", "status": "in_progress", "rationale": "most volume"],
    ["id": "p2", "text": "Find duplicate reports", "status": "pending"],
]

private let secondPlan: JSONValue = [
    ["id": "p1", "text": "Label new issues", "status": "done"],
    ["id": "p2", "text": "Find duplicate reports", "status": "in_progress"],
]

@Test func runsRecordPlanChangesAndTheNextRunSeesThePlan() async throws {
    let harness = RunHarness(
        script: FakeScript(runs: [FakeScript.Run(result: planning(firstPlan))]))
    let first = try await harness.start()
    var updates = try await harness.sink.events(from: 1).filter {
        $0.type == PlanEventType.updated
    }
    #expect(updates.count == 1)
    #expect(updates[0].draft.actor == .steward(StewardID(unchecked: "st_triage")))
    #expect(updates[0].draft.run == first.run)
    #expect(updates[0].payload["reason"] == "Labeled ISSUE-7 as a bug.")
    let book = try PlanBook(try await harness.sink.events(from: 1))
    #expect(
        book.plans[StewardID(unchecked: "st_triage")]?.map(\.status) == [.inProgress, .pending])

    // The same plan again records nothing; the next run's instructions show it.
    _ = try await harness.start()
    updates = try await harness.sink.events(from: 1).filter { $0.type == PlanEventType.updated }
    #expect(updates.count == 1)
    let started = try #require(try await harness.last("run.started"))
    #expect(
        started.payload["instructions"]?.stringValue?.contains(
            "- [p1] in_progress: Label new issues (most volume)") == true)
}

@Test func aChangedPlanReplacesTheOldOne() async throws {
    let harness = RunHarness(
        script: FakeScript(responses: [
            "first": FakeScript.Response(result: planning(firstPlan)),
            "second": FakeScript.Response(result: planning(secondPlan)),
        ]))
    try await harness.lifecycle.create(triageCharter())
    for text in ["first", "second"] {
        _ = try await harness.loop.run(.manual(StewardID(unchecked: "st_triage"), text: text))
    }
    let book = try PlanBook(try await harness.sink.events(from: 1))
    #expect(book.plans[StewardID(unchecked: "st_triage")]?.map(\.status) == [.done, .inProgress])
}

@Test func malformedOrEmptyPlansAreIgnored() {
    func steps(_ pairs: [(String, String)]) -> RunResult {
        RunResult(plan: pairs.map { RunResult.PlanStep(id: $0.0, text: $0.1, status: .pending) })
    }
    #expect(PlanBook.plan(in: steps([("p1", "x"), ("p1", "y")])) == nil)
    #expect(PlanBook.plan(in: steps([("", "x")])) == nil)
    #expect(PlanBook.plan(in: steps([("p1", "")])) == nil)
    #expect(PlanBook.plan(in: steps([])) == nil)
    #expect(PlanBook.plan(in: steps([("p1", "x")]))?.map(\.id) == ["p1"])
}

@Test func onlyIdsTextsAndStatusesCountAsChanges() {
    let plan = [PlanItem(id: "p1", text: "Label", status: .pending, rationale: "a")]
    var reworded = plan
    reworded[0].rationale = "b"
    #expect(!PlanBook.differs(reworded, plan))
    reworded[0].status = .done
    #expect(PlanBook.differs(reworded, plan))
    #expect(PlanBook.differs(plan, nil))
}

@Test func rehearsalsDoNotChangeThePlan() async throws {
    let harness = RunHarness(FakeScript.Run(result: planning(firstPlan)))
    _ = try await harness.start(.rehearsal(CaseContext()))
    #expect(try await harness.last(PlanEventType.updated) == nil)
}
