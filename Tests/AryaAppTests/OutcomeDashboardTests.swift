import AryaDesign
import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let steward = PreviewFixtures.steward
private let metric = MetricDefinition(
    name: "routed", unit: "ratio", direction: .up, target: 0.9)

/// Two runs: one finished after 60 s that labeled and routed, one still going for 30 s.
private func log() -> [FeatureEvent] {
    var log = FeatureEventBuilder(start: now.addingTimeInterval(-600))
    log.add("metric.recorded", ["metric": "routed", "value": 0.5])
    log.add("run.started", run: "run_a", ["input": ["text": "Message A"]])
    for (id, kind) in [("a1", "label"), ("a2", "route")] {
        log.add(
            "action.proposed", run: "run_a",
            ["action": ["id": .string(id), "kind": .string(kind)]])
        log.add("action.executed", run: "run_a", ["action": .string(id)])
    }
    log.add("run.finished", run: "run_a", after: 45, ["status": "completed", "summary": "Done A"])
    log.add("metric.recorded", ["metric": "routed", "value": 0.7])
    log.add("approval.requested", ["approval": "ap_1"])
    log.add("run.started", run: "run_b", at: now.addingTimeInterval(-30), ["input": ["text": "B"]])
    log.add(
        "run.adapter.event", run: "run_b",
        ["message": ["method": "run/event", "params": ["event": ["detail": "reading"]]]])
    return log.events
}

/// A person sees how busy the steward has been, and what waits on them, beside the outcome.
@Test func metricsListOperatingSeriesWithAttentionOnHolds() {
    var state = OutcomeState.build(events: log(), steward: steward, now: now)
    state.metric = metric
    let metrics = OutcomeMetrics.build(events: log(), steward: steward, state: state, now: now)
    let byName = Dictionary(uniqueKeysWithValues: metrics.series.map { ($0.name, $0) })
    #expect(byName["runs"]?.value == "1 / 7d")
    #expect(byName["actions taken"]?.value == "2 / 7d")
    #expect(byName["held for you"]?.tone == .plain)
    #expect(byName["failed runs"]?.tone == .plain)
    #expect(byName["runs"]?.values.count == 14)
}

/// Status and findings use one window: on target today after missed days reads recovering.
@Test func recoveringStatusSharesTheFindingsWindow() {
    let state = OutcomeState.build(
        events: PreviewFixtures.triage(now: now), steward: steward, now: now)
    if state.missed > 0, state.status != .offTrack, state.status != .atRisk {
        #expect(state.status == .recovering || state.status == .paused)
    }
    var fixed = state
    fixed.missed = 3
    fixed.window = 5
    #expect(fixed.missedText == "missed 3 of 5 days")
}

/// A stopped scheduler is not a promise: the line says so, and NOW offers Start serving.
@Test func stoppedSchedulerSaysNextDue() {
    let at = now.addingTimeInterval(600)
    let utc = TimeZone(identifier: "UTC") ?? .current
    #expect(
        OutcomeWake.at(at).schedule(now: now, serving: false, timeZone: utc)
            == "Scheduler stopped · next due 08:10")
    #expect(OutcomeWake.at(at).schedule(now: now, serving: true, timeZone: utc) == "Next run 08:10")
    let serve = FeatureServe(
        serving: false, wakes: [steward: at], states: ["st_other": "unscheduled"])
    #expect(serve.wake(.onDemand, steward: steward) == .at(at))
    #expect(serve.wake(.paused, steward: steward) == .paused)
    #expect(serve.wake(.at(now), steward: "st_other") == .onDemand)
    let state = OutcomeState.build(
        events: PreviewFixtures.triage(now: now), steward: steward, now: now, serve: serve)
    #expect(state.serving == false)
    let nowState = OutcomeNow.build(
        events: PreviewFixtures.triage(now: now), steward: steward, state: state, now: now)
    #expect(nowState.stopped)
    #expect(nowState.next.hasPrefix("Scheduler stopped · next due "))
}

/// Routine reasons read in plain words, not "Version 1".
@Test func versionWordsBecomePlain() {
    let events = PreviewFixtures.triage(now: now)
    let live = LiveCharter.find(events: events, steward: steward)?.version ?? 1
    #expect(
        OutcomeDashboardText.plain("Version \(live) missed it.", events: events, steward: steward)
            == "The current charter missed it.")
    #expect(
        OutcomeDashboardText.plain("Version 99 missed it.", events: events, steward: steward)
            == "Charter version 99 missed it.")
}

/// People read by name, never as raw ids.
@Test func peopleReadByName() {
    #expect(OutcomePeople.name("person:priya") == "Priya")
    #expect(OutcomePeople.name("inbox:MSG-1") == "inbox:MSG-1")
}

/// A kind ruled for two bindings shows once in the policy line.
@Test func policyListsEachKindOnce() {
    let charter: FeatureJSON = [
        "policy": [
            "default": "ask",
            "rules": [
                ["action": "reply", "decision": "auto"], ["action": "reply", "decision": "auto"],
                ["action": "label", "decision": "auto"],
            ],
        ]
    ]
    #expect(OutcomeAutonomy.build(charter: charter).auto == ["reply", "label"])
}

/// NOW shows this steward's live run as the workspace counts it, and the schedule otherwise.
@Test func nowMapsTheWorkspaceLiveState() {
    let events = log()
    let state = OutcomeState.build(events: events, steward: steward, now: now)
    let running = FeatureStewardLive(
        running: FeatureRunFacts(
            running: true, started: now.addingTimeInterval(-35), elapsedSeconds: 35,
            decisions: 1, toolCalls: 2, actionsProposed: 0, actionsApplied: 0, actionsDrafted: 0,
            actionsWaiting: 0, stepIndex: 3, estimatedSteps: 7, dryRun: false),
        run: "run_live", title: "Triage the inbox batch", progress: 0.4, alsoRunning: 1,
        schedule: "running", nextWake: nil, serving: true)
    let busy = OutcomeNow.build(
        events: events, steward: steward, state: state, now: now, live: running)
    #expect(busy.live.map(\.title) == ["Triage the inbox batch"])
    #expect(busy.live.first?.steps == "step 3 of ~7")
    #expect(busy.live.first?.elapsed == 35)
    #expect(busy.alsoRunning == 1)
    let idle = FeatureStewardLive(
        running: nil, alsoRunning: 0, schedule: "waiting",
        nextWake: now.addingTimeInterval(600), serving: false)
    let waiting = OutcomeNow.build(
        events: events, steward: steward, state: state, now: now, live: idle)
    #expect(waiting.live.isEmpty)
    #expect(waiting.stopped)
    #expect(waiting.next.hasPrefix("Scheduler stopped · next due "))
}

/// FINDINGS map the workspace's kinds, read in plain words, and lead with harm.
@Test func findingsMapWorkspaceLinesSeverityFirst() {
    let events = PreviewFixtures.triage(now: now)
    let live = LiveCharter.find(events: events, steward: steward)?.version ?? 1
    let lines = [
        FeatureOverviewFinding(kind: "info", text: "Version \(live) missed it."),
        FeatureOverviewFinding(kind: "opportunity", text: "Mondays spike"),
        FeatureOverviewFinding(kind: "attention", text: "3 approvals wait on you"),
        FeatureOverviewFinding(kind: "attention", text: "A change regressed", link: "proposal"),
        FeatureOverviewFinding(kind: "problem", text: "Refund queue is unowned"),
    ]
    let findings = OutcomeFinding.build(lines, events: events, steward: steward)
    #expect(findings.map(\.kind) == [.negative, .negative, .attention, .positive, .info])
    #expect(findings[0].text == "A change regressed")
    #expect(findings.last?.text == "The current charter missed it.")
}

/// IMPACT shows the workspace's rows with their confidence; zero credit is neutral.
@Test func impactMapsRowsWithConfidence() {
    let impact = OutcomeImpact.build(
        FeatureImpact(
            readings: 8,
            rows: [
                .init(
                    label: "label + route", credit: 0.04, helped: true, actions: 12, windows: 5,
                    confidence: "medium"),
                .init(
                    label: "reply", credit: -0.001, helped: false, actions: 2, windows: 2,
                    confidence: "low"),
            ], summary: "routed +0.04 over 14 actions; most of it from label + route."))
    #expect(impact.rows.first?.detail == "12 actions in 5 of 7 windows · medium confidence")
    #expect(OutcomeImpact.tone(impact.rows[0]) == AryaColor.positive)
    #expect(OutcomeImpact.tone(impact.rows[1]) == AryaColor.inkMuted)
    #expect(OutcomeDashboardText.credit(-0.001) == "±0.00")
}
