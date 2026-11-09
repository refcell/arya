import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

@Test func needsYouShowsTheRunsActionWithItsParams() throws {
    let events = PreviewFixtures.triage(now: now)
    let queue = ApprovalQueue.build(events: events)
    let item = try #require(queue.pending.first { $0.id == PreviewFixtures.pendingApproval })
    let detail = NeedsYouDetail.build(item: item, events: events)
    #expect(detail.action.kind == "assign")
    #expect(detail.action.paramLines == ["to: person:alex"])
    #expect(detail.action.binding == "tracker")
    #expect(RunThreadText.approveLabel(detail.action) == "Approve and assign")
}

@Test func questionsWithoutAnActionShowTheirText() throws {
    let events = PreviewFixtures.triage(now: now)
    let queue = ApprovalQueue.build(events: events)
    let item = try #require(queue.pending.first { $0.id == PreviewFixtures.question })
    let detail = NeedsYouDetail.build(item: item, events: events)
    #expect(detail.action.kind == "question")
    #expect(detail.action.content == "Is ISSUE-9 a duplicate of ISSUE-4, or a new bug?")
    #expect(RunThreadText.approveLabel(detail.action) == "Approve")
}
