import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

@Test func stepsSplitIntoConversationAndWork() {
    let stream = RunStream.build(
        events: PreviewFixtures.triage(now: now), run: PreviewFixtures.finishedRun)
    #expect(!stream.conversation.isEmpty)
    #expect(stream.conversation.allSatisfy { $0.pane == .conversation })
    #expect(stream.work.allSatisfy { $0.pane == .work && $0.pendingApproval == nil })
    #expect(stream.waiting.map(\.pendingApproval) == [PreviewFixtures.pendingApproval])
    #expect(
        stream.conversation.count + stream.work.count + stream.waiting.count == stream.steps.count)
    #expect(stream.conversation.contains { if case .decision = $0.kind { true } else { false } })
}

@Test func workMarksFollowResultsAndOutcomes() {
    let running = ToolCallStep(callID: "c", tool: "search", input: [:])
    var done = running
    done.output = "[]"
    var failed = done
    failed.isError = true
    #expect(StreamStepText.mark(.toolCall(running)) == .running)
    #expect(StreamStepText.mark(.toolCall(done)) == .ok)
    #expect(StreamStepText.mark(.toolCall(failed)) == .failed)
    var action = ProposedActionStep(
        actionID: "a1", kind: "label", target: "tracker:ISSUE-7", summary: "", rationale: "",
        policy: "auto", outcome: .proposed)
    #expect(StreamStepText.mark(.action(action)) == .idle)
    action.outcome = .executed(output: "ok")
    #expect(StreamStepText.mark(.action(action)) == .ok)
    action.outcome = .awaitingApproval(approval: "ap")
    #expect(StreamStepText.mark(.action(action)) == .waiting)
    action.outcome = .rejected(rule: "deny close")
    #expect(StreamStepText.mark(.action(action)) == .failed)
}

@Test func rowsShowClockAndShortTags() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    #expect(StreamStepText.clock(now, timeZone: utc) == "08:00:00")
    #expect(
        StreamStepText.tag(.decision(id: "d", choice: "bug", rationale: "", alternatives: []))
            == "decide")
    #expect(StreamStepText.tag(.message(role: "user", text: "hi")) == "you")
    #expect(StreamStepText.tag(.message(role: "agent", text: "hi")) == "agent")
}

@Test func decisionsReadTheRecordedShapeAndTheFlatOne() {
    var log = FeatureEventBuilder(start: now)
    log.add(
        "run.decision", run: "run_x",
        ["decision": ["id": "d1", "choice": "billing", "rationale": "r"]])
    log.add("run.decision", run: "run_x", ["id": "d2", "choice": "bug"])
    let choices = RunStream.build(events: log.events, run: "run_x").steps.compactMap { step in
        if case .decision(_, let choice, _, _) = step.kind { return choice } else { return nil }
    }
    #expect(choices == ["billing", "bug"])
    #expect(StewardOverview.shortRun("run_01M70Y0DYPH7X28Z") == "01M70Y0DYP")
}
