import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

@Test func improveSummarizesTheRehearsalInOneLine() throws {
    let events = PreviewFixtures.triage(now: now)
    let list = RehearsalList.build(events: events, steward: PreviewFixtures.steward)
    let item = try #require(list.rehearsals.first)
    #expect(ImproveText.summary(item, ready: nil, now: now) == "1/3 passed · 1 leak")
    #expect(ImproveText.meta(item).hasPrefix("charter v1 · casebook "))
    #expect(!ImproveText.meta(item).contains("rh_"))
    #expect(ImproveText.showsScores(item))
}

@Test func caseRowsReadTheRecordedResultElseTheRun() throws {
    let events = PreviewFixtures.triage(now: now)
    let item = try #require(RehearsalList.build(events: events).rehearsals.first)
    let failing = try #require(item.cases.first { $0.id == PreviewFixtures.failingCase })
    #expect(
        ImproveText.wouldHaveDone(failing, events: events)
            == "chose question; label tracker:ISSUE-7; priority low")
    let passing = try #require(item.cases.first { $0.id == "case-0003" })
    #expect(passing.results.isEmpty)
    #expect(
        ImproveText.wouldHaveDone(passing, events: events)
            == "chose question; label tracker:ISSUE-3")
    let leaked = try #require(item.cases.first { $0.id == "case-0009" })
    #expect(ImproveText.wouldHaveDone(leaked, events: events) == "no result")
}

@Test func identicalScoresHideTheColumn() {
    let same = CaseResult(
        id: "c", runs: [], scores: [SampleScore(value: 1, passed: true, notes: [])], leak: false)
    let item = RehearsalItem(
        id: "rh", steward: "st", charterVersion: 1, casebook: "sha256:abc", caseCount: 2,
        samples: 1, proposal: nil, startedAt: now, totals: nil, cases: [same, same])
    #expect(!ImproveText.showsScores(item))
    #expect(ImproveText.summary(item, ready: nil, now: now) == "Running, 2 of 2 scored")
    #expect(CaseOutcome(decisions: [], actions: []).text == "nothing")
}

@Test func caseHeadlinesShowTheChoiceOnly() throws {
    let events = PreviewFixtures.triage(now: now)
    let item = try #require(RehearsalList.build(events: events).rehearsals.first)
    let failing = try #require(item.cases.first { $0.id == PreviewFixtures.failingCase })
    #expect(ImproveText.choice(failing, events: events) == "chose question")
    let leaked = try #require(item.cases.first { $0.id == "case-0009" })
    #expect(ImproveText.choice(leaked, events: events) == "no result")
}

@Test func inspectorStepNamesThePlaceInTheRun() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let events = try await workspace.events()
    let event = try #require(events.last { $0.run == PreviewFixtures.finishedRun })
    let detail = try #require(try await workspace.eventDetail(seq: event.seq))
    let step = try #require(detail.step)
    #expect(step.index == step.count)
    #expect(LedgerText.step(step, title: nil, run: event.run!).hasPrefix("Step \(step.count) of "))
    #expect(LedgerText.step(nil, title: "Labeled it", run: "run_01ABCDEF") == "Labeled it")
}
