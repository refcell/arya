import AryaCore
import AryaRuntime
import Testing

@testable import AryaEval

/// Each run is graded on its executed actions' later follow-up checks; kinds get their own
/// actions' outcomes, choices get the run's, and confidence stays low on little evidence.
@Test func trajectoriesCreditKindsAndChoicesWithOutcomesWeeksLater() async throws {
    // One event per day, so check lags read in days.
    let sink = MemoryEventSink(ambient: .fixed(stepMillis: 86_400_000))
    let steward = StewardID(unchecked: "st_inbox")
    func add(_ run: String, _ type: String, _ payload: JSONValue) async throws {
        _ = try await sink.append(
            RuntimeEventDraft(
                type: type, steward: steward, run: RunID(unchecked: run), actor: .system,
                payload: payload))
    }
    func act(_ run: String, _ id: String, _ kind: String, dryRun: Bool = false) async throws {
        try await add(
            run, "action.proposed", ["action": ["id": .string(id), "kind": .string(kind)]])
        try await add(
            run, "action.executed",
            dryRun ? ["action": .string(id), "dryRun": true] : ["action": .string(id)])
    }
    func check(_ run: String, _ id: String, _ status: String) async throws {
        try await add(run, "action.checked", ["action": .string(id), "status": .string(status)])
    }
    for (run, choice) in [("run_a", "billing"), ("run_b", "billing"), ("run_c", "spam")] {
        try await add(run, "run.decision", ["decision": ["choice": .string(choice)]])
    }
    try await act("run_a", "a1", "label")
    try await act("run_b", "a1", "label")
    try await act("run_b", "a2", "route")
    try await act("run_c", "a1", "label", dryRun: true)
    try await add("run_d", "run.decision", ["decision": ["choice": "spam"]])
    try await act("run_d", "a1", "label")
    try await check("run_a", "a1", "open")
    try await check("run_a", "a1", "resolved")
    try await check("run_b", "a1", "resolved")
    try await check("run_b", "a2", "reopened")

    let view = TrajectoryGrades.view(steward: steward, events: try await sink.events(from: 1))
    #expect(view.runs.map(\.run) == ["run_d", "run_b", "run_a"])
    #expect(view.runs.map(\.grade) == ["pending", "bad", "good"])
    #expect((view.good, view.bad, view.pending) == (1, 1, 1))
    let label = try #require(view.kind("label"))
    #expect((label.resolved, label.reopened, label.pending) == (2, 0, 1) && label.rate == 1)
    #expect(label.confidence > 0.3 && label.confidence < 0.4)
    #expect(label.line.hasPrefix("label: resolved 2 of 2, checked a median "))
    #expect(view.kind("route")?.rate == 0 && view.kind("route")?.confidence == 0)
    let billing = try #require(view.credits.first { $0.id == "choice:billing" })
    #expect((billing.resolved, billing.reopened) == (1, 1))
    #expect(view.credits.first { $0.id == "choice:spam" }?.line == "spam: 1 not checked yet")
    #expect(view.runs.last?.lagDays ?? 0 >= 7)
    #expect(
        view.sentence.hasPrefix(
            "2 of 3 runs have checked outcomes: 1 good, 1 reopened; 1 still open"))
    #expect(view.sentence.contains("best evidence: label: resolved 2 of 2"))
}

@Test func trajectorySentencesWithoutSettledOutcomes() {
    #expect(
        TrajectoryGrades.sentence(good: 0, bad: 0, pending: 0, credits: [])
            == "No executed actions to grade yet.")
    #expect(
        TrajectoryGrades.sentence(good: 0, bad: 0, pending: 2, credits: []).hasPrefix(
            "2 runs acted"))
    #expect(TrajectoryGrades.wilsonLower(0, 0) == 0)
    #expect(TrajectoryGrades.wilsonLower(20, 20) > TrajectoryGrades.wilsonLower(2, 2))
}
