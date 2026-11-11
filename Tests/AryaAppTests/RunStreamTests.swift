import Foundation
import Testing

@testable import AryaApp

private func stream(_ run: String = PreviewFixtures.finishedRun) -> RunStream {
    RunStream.build(events: PreviewFixtures.triage(now: FeatureTestClock.now), run: run)
}

@Test func finishedRunProjectsStepsInOrder() {
    let run = stream()
    #expect(
        run.status
            == .finished(status: "completed", summary: "Labeled ISSUE-7 and asked to assign it."))
    let titles = run.steps.map { StreamStepText.title($0.kind) }
    #expect(
        titles == [
            "Started by manual trigger", "Reading ISSUE-7.", "Read the tracker", "bug",
            "Label ISSUE-7", "Assign ISSUE-7",
            "Labeled ISSUE-7 and asked to assign it.",
        ])
    #expect(run.steps.map(\.number) == Array(1...7))
    #expect(run.steward == PreviewFixtures.steward)
}

@Test func toolCallsJoinTheirResults() throws {
    guard case .toolCall(let call) = stream().steps[2].kind else {
        Issue.record("step 3 is not a tool call")
        return
    }
    #expect(call.tool == "tracker.get")
    #expect(call.input.compactText == #"{"id":"ISSUE-7"}"#)
    #expect(call.output?["title"]?.string == "Login page times out")
    #expect(call.isError == false)
    #expect(abs((call.durationSeconds ?? 0) - 1.2) < 0.001)
}

@Test func actionsCarryPolicyAndOutcome() {
    let actions = stream().steps.compactMap { step -> ProposedActionStep? in
        if case .action(let action) = step.kind { return action }
        return nil
    }
    #expect(actions.map(\.policy) == ["auto", "ask"])
    #expect(actions[0].outcome == .executed(output: "labeled"))
    #expect(actions[1].outcome == .awaitingApproval(approval: PreviewFixtures.pendingApproval))
    #expect(stream().pendingApprovals == [PreviewFixtures.pendingApproval])
}

@Test func liveRunIsRunningUntilItFinishes() {
    let live = stream(PreviewFixtures.liveRun)
    #expect(live.status == .running)
    #expect(live.status.word == "running")
    guard case .toolCall(let call) = live.steps.last?.kind else {
        Issue.record("last step is not a tool call")
        return
    }
    #expect(call.output == nil)
}

@Test func approvalDecisionsUpdateTheAction() async throws {
    let workspace = PreviewWorkspace.triage(now: FeatureTestClock.now)
    try await workspace.record(.deny(approval: PreviewFixtures.pendingApproval, reason: "on leave"))
    let run = RunStream.build(events: await workspace.events(), run: PreviewFixtures.finishedRun)
    #expect(run.pendingApprovals.isEmpty)
    guard case .action(let action) = run.steps[5].kind else {
        Issue.record("step 6 is not an action")
        return
    }
    #expect(
        action.outcome == .denied(approval: PreviewFixtures.pendingApproval, reason: "on leave"))
    #expect(StreamStepText.outcome(action.outcome) == "Denied: on leave")
}

@Test func failuresAndAdapterNoiseProject() {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    let adapter = FeatureActor(kind: .adapter, id: "fake")
    log.add("run.started", run: "r", ["trigger": "case"])
    log.add(
        "run.adapter.event", run: "r", actor: adapter, ["direction": "in", "message": ["raw": "x"]])
    log.add(
        "run.adapter.event", run: "r", actor: adapter,
        PreviewFixtures.wire(1, ["kind": "thinking", "text": "hm"]))
    log.add(
        "run.adapter.event", run: "r", actor: adapter,
        PreviewFixtures.wire(2, ["kind": "error", "message": "slow"]))
    log.add(
        "run.adapter.event", run: "r", actor: adapter,
        PreviewFixtures.wire(3, ["kind": "tool_result", "id": "unknown"]))
    log.add("action.rejected", run: "r", ["action": "unknown"])
    log.add("run.failed", run: "r", ["reason": "interrupted", "detail": "adapter gone"])
    log.add("run.started", run: "other")
    let run = RunStream.build(events: log.events, run: "r")
    #expect(run.status == .failed(reason: "interrupted (adapter gone)"))
    #expect(
        run.steps.map { StreamStepText.title($0.kind) } == [
            "Started by case trigger", "hm", "Error: slow",
            "Run failed: interrupted (adapter gone)",
        ])
    let step = run.steps[1]
    #expect(
        StreamStepText.spoken(step, now: step.at.addingTimeInterval(120))
            == "Step 2, thinking, hm, 2m")
}

@Test func toolCallCaptionsAndRunningState() {
    var call = ToolCallStep(callID: "t1", tool: "tracker.get", input: [:])
    #expect(StreamStepText.toolCaption(call) == "running")
    #expect(StreamStepText.isRunning(.toolCall(call)))
    call.output = "ok"
    call.durationSeconds = 1.25
    #expect(StreamStepText.toolCaption(call) == "ok · 1.2 s")
    call.isError = true
    call.durationSeconds = nil
    #expect(StreamStepText.toolCaption(call) == "failed")
    #expect(StreamStepText.isRunning(.toolCall(call)) == false)
    #expect(RunStatus.running.aryaStatus == .running)
    #expect(RunStatus.failed(reason: "x").aryaStatus == .failed)
}

@Test func proxyToolRecordsReplaceAdapterToolNotifications() {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    let adapter = FeatureActor(kind: .adapter, id: "fake")
    log.add(
        "run.adapter.event", run: "r", actor: adapter,
        PreviewFixtures.wire(1, ["kind": "tool_call", "id": "t1", "tool": "tracker.get"]))
    log.add("run.tool.call", run: "r", ["id": "t1", "tool": "tracker.get", "input": [:]])
    log.add("run.tool.result", run: "r", ["id": "t1", "output": "ok", "isError": false])
    let steps = RunStream.build(events: log.events, run: "r").steps
    #expect(steps.count == 1)
    guard case .toolCall(let call) = steps.first?.kind else {
        Issue.record("not a tool call")
        return
    }
    #expect(call.output == "ok")
}

@Test func proposedActionsCarryTheirPolicyRule() {
    let run = RunStream.build(
        events: PreviewFixtures.triage(now: FeatureTestClock.now), run: PreviewFixtures.finishedRun)
    guard case .action(let label) = run.steps[4].kind else {
        Issue.record("step 5 is not an action")
        return
    }
    #expect(label.rule == "auto label")
    #expect(label.summary == "Wants to label tracker:ISSUE-7.")
}
