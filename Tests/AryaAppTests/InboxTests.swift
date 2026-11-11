import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

@Test func inboxHoldsOnlyQuestionsToPeople() throws {
    let list = InboxList.build(events: PreviewFixtures.triage(now: now))
    #expect(list.items.map(\.id) == [PreviewFixtures.question])
    #expect(list.people == ["person:alex"])
    #expect(list.waiting == 1)
    let item = try #require(list.items.first)
    #expect(item.run == PreviewFixtures.liveRun)
    #expect(InboxText.person("person:alex", waiting: 1) == "Alex · 1 waiting")
    #expect(InboxText.person("person:alex", waiting: 0) == "Alex")
}

@Test func answeringRecordsTheAnswerAsTheGrantNote() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    await #expect(throws: FeatureWriteError.answerEmpty) {
        try await workspace.record(.answer(approval: PreviewFixtures.question, text: "  "))
    }
    let written = try await workspace.record(
        .answer(approval: PreviewFixtures.question, text: " A duplicate of ISSUE-4. "))
    #expect(written.map(\.type) == ["approval.granted"])
    #expect(written[0].payload["note"] == "A duplicate of ISSUE-4.")
    let item = try #require(InboxList.build(events: await workspace.events()).items.first)
    #expect(item.state == .answered("A duplicate of ISSUE-4.", by: .localUser))
    #expect(InboxText.state(item.state) == "Answered by you: A duplicate of ISSUE-4.")
    await #expect(throws: FeatureWriteError.alreadyDecided(PreviewFixtures.question)) {
        try await workspace.record(.answer(approval: PreviewFixtures.question, text: "again"))
    }
}

@Test func waitingQuestionsSortFirstAndDeclinesKeepTheirNote() {
    var log = FeatureEventBuilder(start: now)
    for id in ["q1", "q2"] {
        log.add(
            "approval.requested",
            ["approval": .string(id), "kind": "question", "question": "?", "to": "person:sam"])
    }
    log.add("approval.denied", actor: .localUser, ["approval": "q2", "note": "Not mine."])
    let list = InboxList.build(events: log.events)
    #expect(list.items.map(\.id) == ["q1", "q2"])
    #expect(InboxText.state(list.items[1].state) == "Declined by you: Not mine.")
}

@Test func overviewSummarizesTheSteward() async throws {
    let events = PreviewFixtures.triage(now: now)
    let overview = StewardOverview.build(events: events, steward: PreviewFixtures.steward)
    #expect(overview.charterVersion == 1)
    #expect(overview.lastRun == PreviewFixtures.liveRun)
    #expect(overview.waitingQuestions == 1)
    #expect(overview.summary.hasPrefix("Charter v1 · not ready · last run 0002 running"))
    #expect(overview.summary.contains("1 question for people"))
    let empty = StewardOverview.build(events: [], steward: "st_none")
    #expect(empty.summary == "no runs yet")
}
