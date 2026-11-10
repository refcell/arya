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
    #expect(byName["held for you"]?.tone == .attention)
    #expect(byName["failed runs"]?.tone == .plain)
    #expect(byName["runs"]?.values.count == 14)
}

/// A run in progress shows what it is doing and how far along it is against a typical run.
@Test func nowShowsTheLiveRunWithProgress() throws {
    let state = OutcomeNow.build(events: log(), steward: steward, wake: .onDemand, now: now)
    let live = try #require(state.live.first)
    #expect(live.run == "run_b")
    #expect(live.title == "B")
    #expect(live.doing == "reading")
    #expect(live.progress.map { $0 > 0 && $0 <= 0.95 } == true)
    let idle = OutcomeNow.build(
        events: Array(log().prefix(8)), steward: steward, wake: .onDemand, now: now)
    #expect(idle.live.isEmpty)
    #expect(idle.last?.hasPrefix("Done A · ") == true)
}

/// Credit goes to the kinds executed between readings, so a person sees what moved it.
@Test func impactCreditsActionsBetweenReadings() throws {
    let impact = try #require(OutcomeImpact.build(events: log(), steward: steward, metric: metric))
    #expect(impact.readings == 2)
    #expect(Set(impact.rows.map(\.kind)) == ["label", "route"])
    #expect(abs((impact.rows.first?.credit ?? 0) - 0.1) < 0.0001)
    #expect(impact.rows.allSatisfy(impact.helped))
    #expect(OutcomeDashboardText.credit(-0.03) == "−0.03")
    #expect(OutcomeImpact.build(events: [], steward: steward, metric: metric) == nil)
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
    #expect(texts.contains { $0.contains("case-0005 worse in rehearsal") })
    #expect(texts.contains { $0.contains("wait on you") || $0.contains("waits on you") })
    #expect(texts.contains { $0.contains("missed its target") })
}
