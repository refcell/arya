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

@Test func improveHeadlinePrefersTheWorkspaceSentence() throws {
    let events = PreviewFixtures.triage(now: now)
    let item = try #require(RehearsalList.build(events: events).rehearsals.first)
    let written = FeatureImproveSummary(
        rehearsal: item.id, rehearsalText: "Passed 1 of 3 cases on triage (charter v1).",
        ready: false, markedReady: false, readinessText: "not ready: 2 cases failed",
        readinessReasons: ["2 cases failed"], cases: [], gates: [:])
    #expect(
        ImproveText.headline(item, written: written, ready: nil, now: now)
            == "Passed 1 of 3 cases on triage (charter v1).")
    #expect(
        ImproveText.headline(item, written: nil, ready: nil, now: now)
            == ImproveText.summary(item, ready: nil, now: now))
}

@Test func correctionsReplaceTheChoiceInTheRecordedResult() throws {
    let events = PreviewFixtures.triage(now: now)
    let item = try #require(RehearsalList.build(events: events).rehearsals.first)
    let failing = try #require(item.cases.first { $0.id == PreviewFixtures.failingCase })
    let expected = ImproveText.expected(failing, choice: "bug")
    #expect(expected["decisions"]?.array?.first?["choice"]?.string == "bug")
    #expect(expected["actions"]?.array?.count == 1)
    #expect(expected["summary"] == nil)
    let leaked = try #require(item.cases.first { $0.id == "case-0009" })
    #expect(ImproveText.expected(leaked, choice: "spam") == ["decisions": [["choice": "spam"]]])
}

@Test func whatIfReplaysTheNewestLiveRun() {
    let events = PreviewFixtures.triage(now: now)
    let run = ImproveText.latestLiveRun(events, steward: PreviewFixtures.steward)
    #expect(run != nil)
    #expect(run != "run_r3" && run != "run_r7")
}

@Test func theReviewCardReadsTheDifferenceAndSourceInWords() {
    #expect(
        ReviewText.difference("decisions[0].choice: expected account, got security")
            == "Chose security; the person chose account")
    #expect(
        ReviewText.difference("decisions[0].label: expected spam, got bug")
            == "label: would be bug; the person had spam")
    let actions = ReviewText.difference(
        #"actions: expected [{"kind":"label","target":"inbox:MSG-101"}], got nothing"#)
    #expect(actions.hasPrefix("Would do nothing; the person did label "))
    #expect(!actions.contains("inbox:") && !actions.contains("{"))
    #expect(
        ReviewText.difference(#"decisions: expected [{"choice":"billing"}], got []"#)
            == "Would choose nothing; the person chose billing")
    let source = ReviewText.source(
        "history history-export.json item MSG-120 by person:sam at 2026-10-09T09:00:00Z, "
            + "reopened: Rerouted from security to account.",
        now: now)
    #expect(source.hasPrefix("MSG-120 · Sam · "))
    #expect(source.hasSuffix(" · reopened: Rerouted from security to account."))
    #expect(!source.contains("person:") && !source.contains("T09:00"))
    #expect(ReviewText.source("seeded by hand", now: now) == "seeded by hand")
    #expect(ReviewText.source("by sam at noon", now: now) == "by sam at noon")
}
