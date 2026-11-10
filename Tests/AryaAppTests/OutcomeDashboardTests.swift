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

/// A run in progress shows what it is doing and how far along it is against a typical run.
@Test func nowShowsTheLiveRunWithProgress() throws {
    let ledgerState = OutcomeState.build(events: log(), steward: steward, now: now)
    let state = OutcomeNow.build(events: log(), steward: steward, state: ledgerState, now: now)
    let live = try #require(state.live.first)
    #expect(live.run == "run_b")
    #expect(live.title == "B")
    #expect(live.doing == "reading")
    #expect(live.progress.map { $0 > 0 && $0 <= 0.95 } == true)
    let idle = OutcomeNow.build(
        events: Array(log().prefix(8)), steward: steward, state: ledgerState, now: now)
    #expect(idle.live.isEmpty)
    #expect(idle.last?.hasPrefix("Done A · ") == true)
}

/// Kinds that always run together are not split: IMPACT says so in one honest line.
@Test func impactDoesNotSplitKindsThatAlwaysRunTogether() throws {
    let impact = try #require(OutcomeImpact.build(events: log(), steward: steward, metric: metric))
    #expect(impact.rows.isEmpty)
    #expect(impact.together == ["label", "route"])
    #expect(
        impact.summary
            == "Metric +0.20 over 2 actions; label and route always ran together, so the "
            + "change is not split by action.")
    #expect(OutcomeDashboardText.credit(-0.03) == "−0.03")
    #expect(OutcomeImpact.build(events: [], steward: steward, metric: metric) == nil)
}

/// Kinds that ran in different windows get credit weighted by their share of each window.
@Test func impactWeightsSeparableKindsByShare() throws {
    var log = FeatureEventBuilder(start: now.addingTimeInterval(-600))
    func act(_ id: String, _ kind: String) {
        log.add(
            "action.proposed", run: "r", ["action": ["id": .string(id), "kind": .string(kind)]])
        log.add("action.executed", run: "r", ["action": .string(id)])
    }
    log.add("metric.recorded", ["metric": "routed", "value": 0.5])
    act("a1", "label")
    act("a2", "label")
    act("a3", "route")
    log.add("metric.recorded", ["metric": "routed", "value": 0.8])
    act("a4", "label")
    log.add("metric.recorded", ["metric": "routed", "value": 0.7])
    let impact = try #require(
        OutcomeImpact.build(events: log.events, steward: steward, metric: metric))
    let byKind = Dictionary(uniqueKeysWithValues: impact.rows.map { ($0.kind, $0) })
    // label: 2/3 of +0.3 then all of −0.1 = +0.1; route: 1/3 of +0.3 = +0.1.
    #expect(abs((byKind["label"]?.credit ?? 0) - 0.1) < 0.0001)
    #expect(abs((byKind["route"]?.credit ?? 0) - 0.1) < 0.0001)
    #expect(byKind["label"]?.windows == 2)
    #expect(byKind["route"]?.windows == 1)
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

/// Findings name a missed target, waiting approvals, and a proposal that made a case worse.
@Test func findingsNameWhatNeedsAttention() throws {
    let base = PreviewFixtures.triage(now: now)
    let live = try #require(LiveCharter.find(events: base, steward: steward)?.charter)
    let events =
        base
        + ProposalFixtures.events(live: live, steward: steward, start: now.addingTimeInterval(1))
    let snapshot = OutcomeSnapshot.build(events: events, steward: steward, now: now, lastSeen: nil)
    let findings = OutcomeFinding.build(
        events: events, steward: steward, state: snapshot.state, recap: snapshot.recap, now: now)
    let texts = findings.map(\.text)
    #expect(texts.contains { $0.contains("cases worse in rehearsal (case-0005)") })
    // Severity first: harm leads, then what waits on you, then good news, then notes.
    let rank: [OutcomeFinding.Kind: Int] = [.negative: 0, .attention: 1, .positive: 2, .info: 3]
    let ranks = findings.map { rank[$0.kind] ?? 9 }
    #expect(ranks == ranks.sorted())
    #expect(findings.first?.kind == .negative)
    #expect(texts.contains { $0.contains("wait on you") || $0.contains("waits on you") })
    #expect(
        texts.contains { $0.contains("missed its target") } == (snapshot.state.missed > 0))
}

/// NOW shows what the rail and status bar show: a run the workspace reports live, with its
/// step count and latest step, even before the ledger projection sees it.
@Test func nowShowsTheShellsLiveRuns() {
    let events = log()
    let state = OutcomeState.build(events: events, steward: steward, now: now)
    let line = LiveLine(
        run: "run_shell", steward: steward, name: "Triage", steps: 3,
        lastStep: "Labeling MSG-212", progress: 0.4, started: now.addingTimeInterval(-30))
    let other = LiveLine(
        run: "run_other", steward: "st_other", name: "Other", steps: 1, lastStep: nil,
        progress: nil, started: now)
    let built = OutcomeNow.build(
        events: events, steward: steward, state: state, now: now, running: [line, other])
    let live = built.live.first { $0.run == "run_shell" }
    #expect(live?.steps == 3)
    #expect(live?.doing == "Labeling MSG-212")
    #expect(live?.progress == 0.4)
    #expect(live?.elapsed == 30)
    #expect(!built.live.contains { $0.run == "run_other" })
    #expect(OutcomeDashboardText.credit(0.001) == "±0.00")
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
