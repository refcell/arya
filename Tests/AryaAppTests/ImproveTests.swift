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
