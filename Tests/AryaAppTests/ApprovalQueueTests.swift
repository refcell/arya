import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

/// Two pending approvals for two stewards, requested in order.
private func twoPending() -> [FeatureEvent] {
    var log = FeatureEventBuilder(start: now.addingTimeInterval(-600))
    for (steward, n) in [("st_triage", 1), ("st_spend", 2)] {
        let action: FeatureJSON = ["id": "a1", "kind": "comment", "target": "tracker:ISSUE-\(n)"]
        log.add(
            "action.proposed", steward: steward, run: "run_\(n)",
            ["action": action, "disposition": "ask", "reason": "default ask"])
        log.add(
            "approval.requested", steward: steward, run: "run_\(n)",
            ["approval": "ap_\(n)", "kind": "action", "action": action, "to": "local"])
    }
    return log.events
}

@Test func pendingApprovalsAreOldestFirstWithTheirAction() {
    let queue = ApprovalQueue.build(events: twoPending())
    #expect(queue.pending.map(\.id) == ["ap_1", "ap_2"])
    #expect(queue.pending[1].target == "tracker:ISSUE-2")
    #expect(queue.pending[1].summary == "Wants to comment tracker:ISSUE-2.")
    #expect(queue.pending[1].actionID == "a1")
    #expect(queue.pending[1].approveLabel == "Approve and comment")
    #expect(queue.decided.isEmpty)
}

@Test func queueFiltersBySteward() {
    let queue = ApprovalQueue.build(events: twoPending(), steward: "st_spend")
    #expect(queue.pending.map(\.id) == ["ap_2"])
}

@Test func actionIdsAreScopedToTheirRun() {
    // Both runs use action id a1; each approval must pick its own run's action.
    let queue = ApprovalQueue.build(events: twoPending())
    #expect(queue.pending.map(\.target) == ["tracker:ISSUE-1", "tracker:ISSUE-2"])
}

@Test func decisionsRecordTheLocalUserAsActor() async throws {
    let workspace = PreviewWorkspace(events: twoPending(), now: now)
    try await workspace.record(.approve(approval: "ap_1"))
    try await workspace.record(.deny(approval: "ap_2", reason: "over budget"))
    let queue = ApprovalQueue.build(events: await workspace.events())
    #expect(queue.pending.isEmpty)
    #expect(queue.decided.map(\.id) == ["ap_2", "ap_1"])
    let denied = try #require(queue.decided[0].decision)
    #expect(denied.verdict == .denied)
    #expect(denied.actor == .localUser)
    #expect(
        ApprovalText.verdict(denied, now: denied.at) == "Denied by local: over budget · just now")
    let granted = try #require(queue.decided[1].decision)
    #expect(
        ApprovalText.verdict(granted, now: granted.at.addingTimeInterval(90))
            == "Approved by local · 1m ago")
}

@Test func expiredApprovalsLeaveTheQueue() {
    var events = twoPending()
    var log = FeatureEventBuilder(start: now)
    log.add(
        "approval.expired", run: "run_1", actor: FeatureActor(kind: .system, id: "arya"),
        ["approval": "ap_1"])
    var expired = log.events[0]
    expired.seq = events.count + 1
    events.append(expired)
    let queue = ApprovalQueue.build(events: events)
    #expect(queue.pending.map(\.id) == ["ap_2"])
    #expect(queue.decided.first?.decision?.verdict == .expired)
}

@Test func questionsQueueWithTheirText() {
    var log = FeatureEventBuilder(start: now)
    log.add(
        "approval.requested", run: "run_q",
        ["approval": "ap_q", "kind": "question", "question": "Which label fits?", "to": "local"])
    let item = ApprovalQueue.build(events: log.events).pending[0]
    #expect(item.kind == "question")
    #expect(item.summary == "Which label fits?")
    #expect(item.approveLabel == "Approve")
}

@Test func metaLineNamesStewardRunAndTime() {
    let item = ApprovalQueue.build(events: PreviewFixtures.triage(now: now)).pending[0]
    #expect(item.id == PreviewFixtures.pendingApproval)
    #expect(item.summary == "Wants to assign tracker:ISSUE-7.")
    #expect(item.rationale == "Alex owns the login page.")
    let meta = ApprovalText.meta(item, now: item.requestedAt.addingTimeInterval(300))
    #expect(meta == "st_triage · run_0001 · 5m ago")
}

@Test func streamCardMatchesTheQueueItem() throws {
    let events = PreviewFixtures.triage(now: now)
    let run = RunStream.build(events: events, run: PreviewFixtures.finishedRun)
    let step = run.steps[5]
    guard case .action(let action) = step.kind,
        case .awaitingApproval(let approval) = action.outcome
    else {
        Issue.record("step 6 is not waiting for approval")
        return
    }
    let context = StepContext(steward: run.steward, run: run.run, decide: { _ in })
    let card = StreamStepText.approval(action, approval, step: step, context: context)
    let queued = ApprovalQueue.build(events: events).pending[0]
    #expect(card.id == queued.id)
    #expect(card.summary == queued.summary)
    #expect(card.target == queued.target)
}
