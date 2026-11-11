import AryaDesign
import Foundation
import SwiftUI
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

/// Guardrail metrics come from the workspace's statuses, red when one is off track; the
/// primary stays on the chart, and ledger-only metric rows give way to the read.
@Test func metricsShowGuardrailsFromTheWorkspace() {
    var state = OutcomeState.build(events: log(), steward: steward, now: now)
    state.metric = metric
    let statuses = [
        FeatureMetricStatus(
            name: "triaged_within_1h", unit: "ratio", direction: "up", target: 0.95,
            role: "primary", current: 0.9, trend: [0.8, 0.9], status: "off_track",
            movement: "improving", line: "primary"),
        FeatureMetricStatus(
            name: "reopen_rate", unit: "ratio", direction: "down", target: 0.05,
            role: "guardrail", current: 0.08, trend: [0.04, nil, 0.08], status: "off_track",
            movement: "worsening",
            line: "reopen_rate 0.08 ratio, target ≤ 0.05: off track, worsening."),
    ]
    let metrics = OutcomeMetrics.build(
        events: log(), steward: steward, state: state, now: now, statuses: statuses)
    let guardrails = metrics.series.filter(\.guardrail)
    #expect(guardrails.map(\.name) == ["reopen rate"])
    #expect(guardrails.first?.value == "0.08 / ≤ 0.05")
    #expect(guardrails.first?.tone == .negative)
    #expect(guardrails.first?.values == [0.04, 0.08])
    #expect(!metrics.series.contains { $0.name == "triaged_within_1h" })
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
    #expect(busy.live.first?.elapsed == "35 s")
    #expect(busy.alsoRunning == 1)
    // The clock ticks from the run's start: 5 s later NOW reads 40 s.
    let ticking = OutcomeNow.build(
        events: events, steward: steward, state: state, now: now.addingTimeInterval(5),
        live: running)
    #expect(ticking.live.first?.elapsed == "40 s")
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

/// IMPACT shows the workspace's rows verbatim, never its own window count (it once read "12
/// of 11 windows" from readings - 1); zero credit is neutral.
@Test func impactMapsRowsWithConfidence() {
    let impact = OutcomeImpact.build(
        FeatureImpact(
            readings: 8,
            rows: [
                .init(
                    label: "label + route", credit: 0.04, helped: true, confidence: "medium",
                    line: "label + route: +0.040 over 12 actions in 12 of 12 windows, "
                        + "medium confidence"),
                .init(
                    label: "reply", credit: -0.001, helped: false, confidence: "low",
                    line: "reply: -0.001 over 2 actions in 2 of 12 windows, low confidence"),
            ], summary: "routed +0.04 over 14 actions; most of it from label + route."))
    #expect(impact.rows.first?.detail == "12 actions in 12 of 12 windows, medium confidence")
    #expect(OutcomeImpact.detail("no split") == "no split")
    #expect(OutcomeImpact.tone(impact.rows[0]) == AryaColor.positive)
    #expect(OutcomeImpact.tone(impact.rows[1]) == AryaColor.inkMuted)
    #expect(OutcomeDashboardText.credit(-0.001) == "±0.00")
}

/// METRICS' runs row is the workspace's run history line verbatim, the same count the
/// inspector shows (it once read "19 / 7d" from the ledger beside "14 runs in 7 days").
@Test func metricsRunCountsComeFromRunHistory() {
    let events = PreviewFixtures.triage(now: now)
    let state = OutcomeState.build(events: events, steward: PreviewFixtures.steward, now: now)
    let history = FeatureRunHistory(
        runs: [2, 0, 3, 1, 4, 2, 2], failed: [0, 0, 1, 0, 0, 0, 0], failedTotal: 1,
        line: "14 runs in 7 days, 2 today, 1 failed")
    let metrics = OutcomeMetrics.build(
        events: events, steward: PreviewFixtures.steward, state: state, now: now, runs: history)
    let runs = metrics.series.first { $0.name == "runs" }
    #expect(runs?.value == "14 runs in 7 days, 2 today, 1 failed")
    #expect(runs?.values == [2, 0, 3, 1, 4, 2, 2])
    #expect(metrics.series.first { $0.name == "failed runs" }?.value == "1 / 7d")
}

/// A reading just under its target, which the workspace calls off target, shows the decimal
/// that explains it ("0.897 / 0.90"); on target or clearly apart it stays at two.
@Test func aReadingShowsTheDecimalThatExplainsItsStatus() {
    #expect(MetricText.figure(0.897, target: 0.90, offTarget: true) == "0.897 / 0.90")
    #expect(MetricText.figure(0.8996, target: 0.90, offTarget: true) == "0.8996 / 0.90")
    #expect(MetricText.figure(0.902, target: 0.90, offTarget: false) == "0.90 / 0.90")
    #expect(MetricText.figure(0.84, target: 0.90, offTarget: true) == "0.84 / 0.90")
    #expect(MetricText.figure(nil, target: 0.90, offTarget: false) == "— / 0.90")
    #expect(MetricText.reading(12, target: nil, offTarget: false) == "12")
}

@Test func metricKeysReadAsWordsInSentences() {
    #expect(MetricText.name("first_reply_within_1d") == "first reply within 1d")
    #expect(
        MetricText.sentence("routed_within_1h missed its target on 4 of 5 days")
            == "routed within 1h missed its target on 4 of 5 days")
    #expect(MetricText.sentence("Nov 9: 0.95 over 3 readings") == "Nov 9: 0.95 over 3 readings")
}

@Test func aMetricFieldShowsWordsAndStoresTheKey() {
    var stored = "routed_within_1h"
    let field = MetricText.words(Binding(get: { stored }, set: { stored = $0 }))
    #expect(field.wrappedValue == "routed within 1h")
    field.wrappedValue = "reopen rate"
    #expect(stored == "reopen_rate")
}
