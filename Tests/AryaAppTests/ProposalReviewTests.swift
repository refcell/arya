import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let steward = PreviewFixtures.steward

private func reviews() throws -> (
    events: [FeatureEvent], regressed: ProposalReview,
    passing: ProposalReview
) {
    let base = PreviewFixtures.triage(now: now)
    let live = try #require(LiveCharter.find(events: base, steward: steward)?.charter)
    let fixture = ProposalFixtures.events(
        live: live, steward: steward, start: now.addingTimeInterval(60))
    let events = base + fixture
    let list = ChangeList.build(events: events, steward: steward)
    let regressed = try #require(list.open.first { $0.id == ProposalFixtures.regressed })
    let passing = try #require(list.open.first { $0.id == ProposalFixtures.passing })
    return (
        events, ProposalReview.build(regressed, events: events),
        ProposalReview.build(passing, events: events)
    )
}

/// A person deciding on a proposal reads the change and why, never a ULID.
@Test func titleIsTheChangeSentenceAndTheWhy() throws {
    let (_, regressed, _) = try reviews()
    #expect(
        regressed.title
            == "Route security reports before billing: security reports were waiting behind "
            + "billing questions.")
    #expect(!regressed.title.contains("prop_"))
}

/// Without a title the sentence names what changed, still never the id.
@Test func untitledProposalNamesTheChangedFields() throws {
    let (events, _, _) = try reviews()
    var item = try #require(
        ChangeList.build(events: events).open.first { $0.id == ProposalFixtures.passing })
    item.title = item.id
    item.reason = ""
    #expect(ProposalText.title(item, events: events) == CharterText.title(["outcome"]))
}

/// The regressed case shows before → after, so a person sees what would go wrong.
@Test func regressedProposalNamesTheWorseCaseBeforeAndAfter() throws {
    let (_, regressed, passing) = try reviews()
    #expect(regressed.regressed)
    #expect(regressed.worse.map(\.id) == ["case-0005"])
    #expect(regressed.worse.first?.before == "billing")
    #expect(regressed.worse.first?.after == "security")
    let summary = ProposalText.summary(regressed)
    #expect(
        summary.lead + summary.worse + summary.tail
            == "Rehearsal: 7 of 8 cases unchanged, 1 got worse.")
    #expect(summary.worse == "worse")
    #expect(ProposalText.confirm(regressed).contains("case-0005"))
    #expect(!passing.regressed)
    #expect(passing.better.map(\.id) == ["case-0003"])
    let good = ProposalText.summary(passing)
    #expect(good.lead == "Rehearsal: 7 of 8 cases unchanged, 1 got better.")
    #expect(good.worse.isEmpty)
}

/// The charter change shows as a unified diff with counts, without the version bump.
@Test func charterChangeIsAUnifiedDiffWithCounts() throws {
    let (_, regressed, _) = try reviews()
    let diff = try #require(regressed.diff)
    #expect(diff.added == 1)
    #expect(diff.removed == 1)
    #expect(diff.counts == "+1 −1")
    #expect(diff.text.contains("+  \"outcome\": \"Every security report"))
    let removed = try #require(diff.text.range(of: "-  \"outcome\""))
    let added = try #require(diff.text.range(of: "+  \"outcome\""))
    #expect(removed.lowerBound < added.lowerBound)
    #expect(!diff.text.contains("\","))
    #expect(!diff.text.contains("\"version\""))
}

/// An ungated proposal says it is still rehearsing and offers nothing that goes live.
@Test func ungatedProposalIsStillRehearsing() {
    var log = FeatureEventBuilder(start: now)
    log.add("proposal.created", ["proposal": "prop_new", "kind": "charter", "reason": "x"])
    let item = ChangeList.build(events: log.events).open[0]
    let review = ProposalReview.build(item, events: log.events)
    #expect(!review.compared)
    #expect(!review.regressed)
    #expect(!item.canAccept)
    #expect(ProposalText.summary(review).lead.hasPrefix("Rehearsing on past work"))
}

/// Step 5 of the editor says what changes and when it goes live, in plain words.
@Test func editorChangeLineSaysWhenItGoesLive() {
    #expect(
        NewStewardDraft.changeLine(["outcome"])
            == "This changes the outcome. It goes live after rehearsal passes.")
    #expect(
        NewStewardDraft.changeLine(["outcome", "connections", "schedule"])
            == "This changes the outcome, connections and schedule. It goes live after "
            + "rehearsal passes.")
}

/// A paused steward's line says PAUSED instead of a target status it is not working toward.
@Test func pausedStewardReadsPaused() {
    var events = PreviewFixtures.triage(now: now)
    var log = FeatureEventBuilder(start: now)
    log.add("steward.paused")
    events += log.events
    let state = OutcomeState.build(events: events, steward: steward, now: now)
    #expect(state.status == .paused)
    #expect(state.status.word == "paused")
}

/// Context lists what the steward knows, one line each, from charter, memory, and results.
@Test func contextListsPeopleConnectionsNotesAndDecisions() {
    let context = OutcomeContext.build(events: PreviewFixtures.triage(now: now), steward: steward)
    #expect(!context.isEmpty)
    #expect(!context.connections.isEmpty)
    #expect(context.notes.count <= OutcomeContext.limit)
    #expect(context.decisions.count <= OutcomeContext.limit)
    #expect(OutcomeContext.build(events: [], steward: steward).isEmpty)
}
