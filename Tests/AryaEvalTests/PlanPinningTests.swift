import AryaAdapters
import AryaCore
import AryaLedger
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

private let planSteward = StewardID(unchecked: "st_plan")

private struct OneScript: AdapterFactory {
    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        FakeAdapter(
            script: FakeScript(runs: [
                FakeScript.Run(result: [
                    "summary": "ok", "decisions": [["id": "d1", "choice": "bug"]],
                ])
            ]))
    }
}

private func setPlan(_ sink: MemoryEventSink, _ text: String) async throws {
    _ = try await sink.append(
        RuntimeEventDraft(
            type: PlanEventType.updated, steward: planSteward, run: nil,
            actor: .steward(planSteward),
            payload: try CanonicalJSON.jsonValue(
                PlanUpdated(items: [PlanItem(id: "p1", text: text, status: .inProgress)]))))
}

/// The instructions a run was started with.
private func instructions(_ sink: MemoryEventSink, _ run: RunID) async throws -> String {
    let started = try #require(
        try await sink.events(from: 1).first {
            $0.draft.run == run && $0.type == RunEventType.started
        })
    return try EvalPayload.decode(RunStarted.self, started.payload).instructions
}

/// A rehearsal shows the plan its case recorded, never the live one, so re-planning between
/// rehearsals cannot change what the same case is asked.
@Test func rehearsalsUseTheCasePlanNotTheLivePlan() async throws {
    let ambient = Ambient.fixed(stepMillis: 2, seed: 81)
    let sink = MemoryEventSink(ambient: ambient)
    try await StewardLifecycle(sink: sink).create(
        Charter(
            id: planSteward, name: "Planner", outcome: "Issues are triaged.",
            metric: Metric(name: "triaged", unit: "ratio", direction: .up), adapter: "fake"))
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let engine = RunEngine(
        sink: sink, ambient: ambient, adapters: OneScript(),
        dispatcher: ActionDispatcher(
            sink: sink, approvals: approvals, executor: RecordingExecutor(outcomes: [:])),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    let pinned: JSONValue = ["id": "p0", "text": "Label the backlog", "status": "pending"]
    func rehearse(_ context: CaseContext) async throws -> String {
        let outcome = try await engine.run(
            RunRequest(
                steward: planSteward, input: RunInput(kind: .case, text: "Issue ISSUE-1"),
                mode: .rehearsal(context), actor: .system))
        return try await instructions(sink, outcome.run)
    }

    try await setPlan(sink, "Label new issues")
    let first = try await rehearse(CaseContext(plan: [pinned]))
    try await setPlan(sink, "Close stale issues")
    let second = try await rehearse(CaseContext(plan: [pinned]))
    #expect(first == second)
    #expect(first.contains("Label the backlog") && !first.contains("stale"))
    #expect(!(try await rehearse(CaseContext())).contains("## Plan"))

    // A live run sees the live plan; the case made from it pins that plan.
    let live = try await engine.run(.manual(planSteward, text: "Issue ISSUE-2"))
    #expect(try await instructions(sink, live.run).contains("Close stale issues"))
    try await setPlan(sink, "Something else")
    let item = try RunCases.makeCase(try await sink.events(from: 1), run: live.run)
    #expect(item.context.plan.first?["text"] == "Close stale issues")
    #expect(try await rehearse(item.context).contains("Close stale issues"))
}

/// Cases without a plan encode exactly as before, so stored casebooks keep their bytes.
@Test func caseContextOmitsAnEmptyPlan() throws {
    let empty = try CanonicalJSON.string(CaseContext())
    #expect(!empty.contains("plan"))
    let planned = CaseContext(plan: [["id": "p1", "text": "t", "status": "pending"]])
    let decoded = try CanonicalJSON.decode(
        CaseContext.self, from: try CanonicalJSON.encode(planned))
    #expect(decoded == planned)
}
