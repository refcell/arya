import AryaDesign
import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let steward = PreviewFixtures.steward

private func triage() -> OutcomeSnapshot {
    OutcomeSnapshot.build(
        events: PreviewFixtures.triage(now: now), steward: steward, now: now, lastSeen: nil)
}

@Test func statusComparesTheLatestValueWithTheTargetInItsDirection() {
    #expect(OutcomeStatus.of(value: 0.96, target: 0.95, direction: .up) == .onTrack)
    #expect(OutcomeStatus.of(value: 0.93, target: 0.95, direction: .up) == .atRisk)
    #expect(OutcomeStatus.of(value: 0.80, target: 0.95, direction: .up) == .offTrack)
    #expect(OutcomeStatus.of(value: 4, target: 5, direction: .down) == .onTrack)
    #expect(OutcomeStatus.of(value: 5.2, target: 5, direction: .down) == .atRisk)
    #expect(OutcomeStatus.of(value: 9, target: 5, direction: .down) == .offTrack)
    #expect(OutcomeStatus.of(value: nil, target: 5, direction: .down) == .noData)
    #expect(OutcomeStatus.of(value: 1, target: nil, direction: .up) == .noTarget)
}

@Test func headlineLeadsWithTheMetricAgainstItsTarget() {
    let summary = triage().state
    #expect(summary.metric?.name == "triaged_within_1h")
    #expect(summary.latest.map { abs($0 - 0.93) < 1e-9 } == true)
    #expect(summary.status == .atRisk)
    #expect(summary.points.count >= 5)
    #expect(summary.success == "triaged_within_1h at 0.95 or more.")
    #expect(summary.outcome.hasPrefix("Every new issue"))
    #expect(OutcomeText.change(summary.points)?.hasPrefix("+0.") == true)
}

@Test func readinessExplainsWhyNot() {
    let summary = triage().state
    #expect(
        summary.readiness == .notReady(reason: "rehearsal passed 1 of 3; review and mark ready"))
    var log = FeatureEventBuilder(start: now)
    log.add("steward.created", ["charter": PreviewFixtures.charter, "version": 1])
    #expect(
        OutcomeReadiness.build(events: log.events, steward: steward)
            == .notReady(reason: "never rehearsed on past work"))
    log.add("steward.ready", ["charterVersion": 1])
    #expect(
        OutcomeReadiness.build(events: log.events, steward: steward) == .ready(charterVersion: 1))
    #expect(OutcomeReadiness.ready(charterVersion: 1).text == "ready (v1)")
}

@Test func autonomyReadsThePolicy() {
    let autonomy = triage().state.autonomy
    #expect(autonomy.level == .assisted)
    #expect(autonomy.text == "assisted · auto label · never close")
    #expect(OutcomeAutonomy.build(charter: nil).level == .supervised)
    #expect(OutcomeAutonomy.build(charter: ["policy": ["default": "auto"]]).level == .autonomous)
    #expect(OutcomeAutonomy.build(charter: ["policy": ["default": "deny"]]).level == .locked)
}

@Test func nextWakeFollowsTheShortestIntervalFromTheLastIntervalRun() throws {
    var log = FeatureEventBuilder(start: now)
    log.add("steward.created", ["charter": PreviewFixtures.charter, "version": 1])
    log.add("run.started", run: "run_1", after: 100, ["trigger": "interval"])
    let started = try #require(log.events.last?.at)
    let charter = PreviewFixtures.charter
    let wake = OutcomeWake.build(
        events: log.events, steward: steward, charter: charter, now: started.addingTimeInterval(60))
    #expect(wake == .at(started.addingTimeInterval(900)))
    #expect(wake.text(now: started.addingTimeInterval(60)) == "in 14m")
    let late = OutcomeWake.build(
        events: log.events, steward: steward, charter: charter,
        now: started.addingTimeInterval(2000))
    #expect(late == .at(started.addingTimeInterval(2700)))
    log.add("steward.paused")
    #expect(
        OutcomeWake.build(events: log.events, steward: steward, charter: charter, now: now)
            == .paused)
    #expect(
        OutcomeWake.build(
            events: [], steward: steward, charter: ["triggers": [["kind": "manual"]]], now: now)
            == .onDemand)
}

@Test func planShowsTheNewestStepsAndWhatChanged() throws {
    let plan = try #require(triage().plan)
    #expect(plan.steps.map(\.status) == [.done, .doing, .todo, .todo])
    #expect(plan.doneCount == 1)
    #expect(plan.activeCount == 4)
    #expect(plan.added.count == 2)
    #expect(plan.removed == ["Close stale duplicates"])
    #expect(plan.reason?.hasPrefix("Closing is denied") == true)
    #expect(plan.run == PreviewFixtures.liveRun)
    #expect(OutcomePlan.build(events: [], steward: steward) == nil)
}

@Test func activityListsLiveActionsWithReasonsNewestFirst() throws {
    let activity = triage().activity
    #expect(activity.map(\.action) == ["a2", "a1"])
    let assign = try #require(activity.first)
    #expect(assign.state == .waiting)
    #expect(assign.policy == .ask)
    #expect(assign.reason == "Alex owns the login page.")
    let label = try #require(activity.last)
    #expect(label.state == .executed)
    #expect(label.policy == .auto)
    #expect(label.target == "tracker:ISSUE-7")
    #expect(!activity.contains { $0.run.hasPrefix("run_r") })
    #expect(OutcomeActivityText.tally(activity) == "✓ 1  ◷ 1")
    #expect(
        OutcomeActivityText.spoken(label)
            == "label tracker:ISSUE-7, executed, because Bugs get the bug label.")
}

@Test func recapCountsWhatHappenedSinceTheLastVisit() throws {
    let snapshot = triage()
    let recap = snapshot.recap
    #expect(recap.goal.hasPrefix("Every new issue"))
    #expect(recap.lastRun?.run == PreviewFixtures.finishedRun)
    #expect(recap.lastRun?.summary == "Labeled ISSUE-7 and asked to assign it.")
    #expect(recap.pending.map(\.approval) == [PreviewFixtures.pendingApproval])
    #expect(recap.questions == 1)
    #expect(OutcomeRecapText.since(recap) == "1 run ended · 1 action taken")
    #expect(OutcomeRecapText.unresolved(recap)?.hasPrefix("1 approval · 1 question") == true)
    let newest = try #require(PreviewFixtures.triage(now: now).last?.seq)
    let later = OutcomeSnapshot.build(
        events: PreviewFixtures.triage(now: now), steward: steward, now: now, lastSeen: newest)
    #expect(OutcomeRecapText.since(later.recap) == "nothing new")
}

@Test func visitsAreRememberedPerSteward() throws {
    let defaults = try #require(UserDefaults(suiteName: "arya.outcome.tests"))
    defaults.removePersistentDomain(forName: "arya.outcome.tests")
    #expect(OutcomeVisits.lastSeen("st_a", defaults: defaults) == nil)
    OutcomeVisits.record(42, steward: "st_a", defaults: defaults)
    #expect(OutcomeVisits.lastSeen("st_a", defaults: defaults) == 42)
    #expect(OutcomeVisits.lastSeen("st_b", defaults: defaults) == nil)
}

@Test func recapParagraphAppearsOnlyForAReturningPerson() throws {
    let recap = triage().recap
    let utc = try #require(TimeZone(identifier: "UTC"))
    #expect(OutcomeRecapText.paragraph(recap, seenAt: nil, now: now, timeZone: utc) == nil)
    let recent = now.addingTimeInterval(-60)
    #expect(OutcomeRecapText.paragraph(recap, seenAt: recent, now: now, timeZone: utc) == nil)
    let text = try #require(
        OutcomeRecapText.paragraph(
            recap, seenAt: now.addingTimeInterval(-86_400), now: now, timeZone: utc))
    #expect(
        text
            == "Since you looked Jan 14: 1 run ended, 1 action taken. Waiting on you: "
            + "1 approval, 1 question, 2 proposals.")
    // A last look weeks before the news reads as a date, not a remembered visit.
    let stale = try #require(
        OutcomeRecapText.paragraph(
            recap, seenAt: now.addingTimeInterval(-86_400 * 20), now: now, timeZone: utc))
    #expect(stale.hasPrefix("Since Dec 26, 2026: "))
    let quiet = OutcomeRecap(
        goal: "", lastRun: nil, runsSince: 0, actionsSince: [], pending: [], questions: 0,
        failedActions: 0, openProposals: 0)
    #expect(OutcomeRecapText.paragraph(quiet, seenAt: .distantPast, now: now) == nil)
}

@Test func outcomeLineOffersReviewWhenApprovalsWait() {
    #expect(OutcomeText.review(1) == "Review 1 approval")
    #expect(OutcomeText.review(3) == "Review 3 approvals")
    #expect(
        OutcomeText.spoken(triage().state)
            == "triaged_within_1h is 0.93 against a target of 0.95, at risk, missed 5 of 5 days.")
    #expect(OutcomeActivity.State.executed.mark == "✓")
    #expect(OutcomeActivity.State.waiting.mark == "◷")
}

@Test func rehearsalRunsAreRecognizedInEveryRecordedShape() {
    #expect(OutcomeRuns.isRehearsal(["rehearsal": "reh_1", "case": "case-0001"]))
    #expect(OutcomeRuns.isRehearsal(["input": ["kind": "case", "text": "x"]]))
    #expect(OutcomeRuns.isRehearsal(["rehearsal": true]))
    #expect(OutcomeRuns.isRehearsal(["trigger": "case"]))
    #expect(!OutcomeRuns.isRehearsal(["trigger": "manual", "input": ["kind": "manual"]]))
    #expect(!OutcomeRuns.isRehearsal(["rehearsal": false, "trigger": "interval"]))
}

@Test func planStepsReadTheProtocolShape() throws {
    var log = FeatureEventBuilder(start: now)
    log.add(
        "plan.updated",
        [
            "v": 1,
            "steps": [
                ["id": "p1", "text": "Read the inbox", "status": "done"],
                ["id": "p2", "text": "Reply", "status": "in_progress", "rationale": "drafted"],
                ["id": "p3", "text": "Close", "status": "skipped"],
                ["id": "p4", "text": "Escalate", "status": "pending"],
            ],
        ])
    let plan = try #require(OutcomePlan.build(events: log.events, steward: steward))
    #expect(plan.steps.map(\.status) == [.done, .doing, .dropped, .todo])
    #expect(plan.steps[1].note == "drafted")
    #expect(plan.activeCount == 3)
}

@Test func sparklineFallsBackToReadingsWithinOneDay() {
    var log = FeatureEventBuilder(start: now)
    log.add("steward.created", ["charter": PreviewFixtures.charter, "version": 1])
    log.add("metric.recorded", ["metric": "triaged_within_1h", "value": 0.7])
    log.add("metric.recorded", ["metric": "triaged_within_1h", "value": 0.8])
    log.add("metric.recorded", ["metric": "other", "value": 9])
    let state = OutcomeState.build(events: log.events, steward: steward, now: now)
    #expect(state.points.count == 1)
    #expect(state.trend == [0.7, 0.8])
    #expect(triage().state.trend.count >= 5)
}

@Test func riskAndWhyComeFromTheRecordedResultWhenTheEventLacksThem() throws {
    var log = FeatureEventBuilder(start: now)
    log.add("run.started", run: "run_1", ["trigger": "manual"])
    let recorded: FeatureJSON = [
        "id": "a1", "kind": "reply", "target": "inbox:MSG-1", "rationale": "ack",
        "risk": "medium", "why": "The customer is waiting on a refund.",
    ]
    log.add(
        "run.adapter.event", run: "run_1",
        [
            "direction": "in",
            "message": [
                "jsonrpc": "2.0", "method": "run/result",
                "params": ["result": ["actions": [recorded]]],
            ],
        ])
    log.add(
        "action.proposed", run: "run_1",
        [
            "action": ["id": "a1", "kind": "reply", "target": "inbox:MSG-1", "rationale": "ack"],
            "disposition": "ask", "reason": "default ask",
        ])
    let item = try #require(OutcomeActivityFeed.build(events: log.events, steward: steward).first)
    #expect(item.risk == "medium")
    #expect(item.reason == "The customer is waiting on a refund.")
}

@Test func planMarksReadAsStatusNotFailure() {
    #expect(OutcomePlan.status("blocked") == .blocked)
    #expect(OutcomePlan.StepStatus.blocked.mark == "◷")
    #expect(OutcomePlan.StepStatus.blocked.word == "waiting on you")
    #expect(OutcomePlan.status("skipped") == .dropped)
    #expect(OutcomePlan.status("failed") == .failed)
    #expect(OutcomePlan.StepStatus.dropped.mark == OutcomePlan.StepStatus.failed.mark)
}

@Test func scheduleLineShowsNextRunAndRecentTriggers() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(
        OutcomeWake.at(now.addingTimeInterval(3600)).schedule(now: now, timeZone: utc)
            == "Next run \(AryaTime.clock(now.addingTimeInterval(3600), timeZone: utc))")
    #expect(
        OutcomeWake.at(now.addingTimeInterval(3 * 86_400)).schedule(now: now, timeZone: utc)
            == "Next run Nov 17")
    #expect(OutcomeWake.paused.schedule(now: now) == "Paused")
    var log = FeatureEventBuilder(start: now)
    for (index, ok) in [true, true, false, true, true, true].enumerated() {
        let run = "run_\(index)"
        log.add("run.started", steward: "st_triage", run: run, ["trigger": "interval"])
        log.add(ok ? "run.finished" : "run.failed", steward: "st_triage", run: run)
    }
    log.add(
        "run.started", steward: "st_triage", run: "run_r", ["trigger": "case", "rehearsal": true])
    log.add("run.failed", steward: "st_triage", run: "run_r")
    #expect(
        OutcomeWake.triggers(events: log.events, steward: "st_triage")
            == [true, false, true, true, true])
}

/// RECENT's inline diff: one line per parameter, a lone parameter as its value.
@Test func recentWritesReadAsTheRunPaneDiff() {
    #expect(
        OutcomeActivityFeed.writes(["text": "qualified: Pricing page visit"], kind: "note")
            == ["qualified: Pricing page visit"])
    #expect(
        OutcomeActivityFeed.writes(["label": "bug", "queue": "billing"], kind: "label")
            == ["bug", "queue: billing"])
    #expect(
        OutcomeActivityFeed.writes(["body": "Hi\nthere", "to": "ana"], kind: "send_email")
            == ["body: Hi", "to: ana"])
    #expect(OutcomeActivityFeed.writes(nil, kind: "note").isEmpty)
}

@Test func theHeaderTakesItsStatusReasonAndMissedLineFromTheWorkspace() {
    let metric = MetricDefinition(name: "reply_rate", unit: "ratio", direction: .up, target: 0.9)
    // A ledger mean a hair under the bound reads at risk on its own.
    var state = OutcomeState(
        outcome: "", metric: metric,
        points: [MetricPoint(day: Date(timeIntervalSince1970: 0), value: 0.8999, count: 1)],
        status: .atRisk, success: "", readiness: .ready(charterVersion: 1),
        autonomy: OutcomeAutonomy.build(charter: nil), wake: .onDemand, trend: [])
    let primary = FeatureMetricStatus(
        name: "reply_rate", unit: "ratio", direction: "up", target: 0.9, role: "primary",
        current: 0.9, trend: [], status: "on_track", movement: "flat",
        line: "reply_rate 0.90, target ≥ 0.90: on track, flat.")
    state = state.applying(OutcomeReads(metrics: [primary], missedText: .some(nil)))
    #expect(state.status == OutcomeStatus.onTrack)
    #expect(state.reason == "reply_rate 0.90, target ≥ 0.90: on track, flat.")
    #expect(state.missedText == nil)
    let missed = "missed its target on 4 of the last 7 days"
    let recovering = state.applying(OutcomeReads(metrics: [primary], missedText: .some(missed)))
    #expect(recovering.status == OutcomeStatus.recovering)
    #expect(recovering.missedText == missed)
    // Without reads the ledger estimate stands.
    #expect(state.applying(nil) == state)
}
