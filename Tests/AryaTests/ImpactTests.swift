import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private func metric(_ direction: Metric.Direction = .up) throws -> Metric {
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.metric.direction = direction
    return charter.metric
}

@Test func impactSplitsKindsThatRanInDifferentWindows() throws {
    let windows: [(delta: Double, counts: [String: Int])] = [
        (0.10, ["label": 1]), (0.08, ["label": 2]), (-0.02, ["route": 1]),
        (0.06, ["label": 1, "route": 1]), (0.05, ["label": 1]), (0.04, ["label": 1]),
    ]
    let impact = Workspace.attribute(
        windows, steward: "st_inbox", metric: try metric(), readings: 7, rates: [:], limit: 5)
    #expect(impact.rows.map(\.label) == ["label", "route"])
    let label = impact.rows[0]
    #expect(abs(label.credit - 0.30) < 1e-9)
    #expect(label.windows == 5 && label.actions == 6 && label.helped)
    #expect(label.confidenceLevel == "high")
    let route = impact.rows[1]
    #expect(abs(route.credit - 0.01) < 1e-9)
    #expect(route.confidenceLevel == "low")
    #expect(label.line == "label: +0.300 over 6 actions in 5 of 6 windows, high confidence")
    #expect(impact.summary.hasSuffix("most of it from label (high confidence)."))

    // A metric where down is good flips which row helped.
    let down = Workspace.attribute(
        windows, steward: "st_inbox", metric: try metric(.down), readings: 7, rates: [:],
        limit: 5)
    #expect(down.rows.first?.label == "route")
    #expect(down.rows.last?.helped == false)
}

@Test func impactSaysWhenKindsAlwaysRanTogether() throws {
    let windows: [(delta: Double, counts: [String: Int])] = [
        (0.1, ["label": 1, "route": 1]), (0.05, ["label": 2, "route": 1]),
    ]
    let impact = Workspace.attribute(
        windows, steward: "st_inbox", metric: try metric(), readings: 3, rates: [:], limit: 5)
    #expect(impact.rows.isEmpty)
    #expect(impact.together == ["label", "route"])
    #expect(impact.summary.contains("label and route always ran together"))
}

@Test func impactAndOverviewFindingsReadTheLedger() async throws {
    let opened = try await Opened([
        FakeScript.Run(result: liveResult), FakeScript.Run(result: liveResult),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let name = try Charter.load(from: try inboxCharterJSON()).metric.name
    func reading(_ value: Double) async throws {
        _ = try await workspace.sink.append(
            RuntimeEventDraft(
                type: MetricEventType.recorded, steward: StewardID(unchecked: "st_inbox"),
                actor: .system,
                payload: try CanonicalJSON.decode(
                    JSONValue.self,
                    from: try CanonicalJSON.encode(MetricRecorded(metric: name, value: value)))))
    }
    #expect(try await workspace.impact(steward: "st_inbox") == nil)
    try await reading(0.5)
    _ = try await workspace.startRun(steward: "st_inbox", input: "First")
    try await reading(0.6)
    _ = try await workspace.startRun(steward: "st_inbox", input: "Second")
    try await reading(0.7)

    let impact = try #require(try await workspace.impact(steward: "st_inbox"))
    #expect(impact.readings == 3)
    #expect(impact.actions > 0)
    #expect(abs(impact.total - 0.2) < 1e-9)
    #expect(impact.rows.isEmpty)  // label and route always ran together
    #expect(!impact.together.isEmpty)

    let findings = try await workspace.overviewFindings(steward: "st_inbox")
    #expect(findings.contains { $0.kind == "attention" && $0.link?.kind == "approval" })
}

@Test func metricStatusesListPrimaryThenGuardrails() async throws {
    let opened = try await Opened([])
    let workspace = opened.workspace
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.metric.target = 0.5
    charter.guardrailMetrics = [
        Metric(name: "reopen_rate", unit: "ratio", direction: .down, target: 0.1),
        Metric(name: "cost_per_item", unit: "usd", direction: .down),
    ]
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    func reading(_ name: String, _ value: Double) async throws {
        _ = try await workspace.sink.append(
            RuntimeEventDraft(
                type: MetricEventType.recorded, steward: StewardID(unchecked: "st_inbox"),
                actor: .system,
                payload: try CanonicalJSON.decode(
                    JSONValue.self,
                    from: try CanonicalJSON.encode(MetricRecorded(metric: name, value: value)))))
    }
    try await reading(charter.metric.name, 0.75)
    try await reading("reopen_rate", 0.25)

    let metrics = try await workspace.metricStatuses(steward: "st_inbox")
    #expect(metrics.map(\.role) == ["primary", "guardrail", "guardrail"])
    #expect(metrics.map(\.name) == [charter.metric.name, "reopen_rate", "cost_per_item"])
    #expect(metrics[0].current == 0.75 && metrics[0].status == .onTrack)
    #expect(metrics[1].status == .offTrack)
    #expect(metrics[1].line == "reopen_rate 0.25 ratio, target ≤ 0.10: off track.")
    #expect(metrics[2].status == .noTarget && metrics[2].current == nil)
    #expect(metrics[2].line == "cost_per_item no readings: no target.")
    #expect(metrics.allSatisfy { $0.movement == "unknown" && !$0.trend.isEmpty })

    let down = Metric(name: "m", unit: "s", direction: .down)
    #expect(Workspace.movement(current: 40, previous: 50, metric: down) == "improving")
    #expect(Workspace.movement(current: 60, previous: 50, metric: down) == "worsening")
    #expect(Workspace.movement(current: 50.1, previous: 50, metric: down) == "flat")

    // Adding a guardrail metric changes what the steward owns.
    var tighter = charter
    tighter.guardrailMetrics?.removeLast()
    let impact = ProposalImpact(live: tighter, proposed: charter)
    #expect(impact.kinds.contains("metric"))
    #expect(
        impact.owns.last
            == "guardrail metrics reopen_rate ≤ 0.1 → reopen_rate ≤ 0.1, cost_per_item")

    // Validation: names must be set and distinct from the primary.
    charter.guardrailMetrics = [Metric(name: charter.metric.name, unit: "x", direction: .up)]
    #expect(charter.validate().map(\.path) == ["guardrailMetrics[0].name"])
    // A charter with none encodes exactly as before.
    charter.guardrailMetrics = nil
    #expect(
        !String(decoding: try CanonicalJSON.encode(charter), as: UTF8.self)
            .contains("guardrailMetrics"))
}

@Test func oneEvaluationWindowForHeaderFindingsAndTrends() async throws {
    let opened = try await Opened([])
    let workspace = opened.workspace
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.metric.target = 0.5
    charter.metric.windowDays = 3
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    _ = try await workspace.sink.append(
        RuntimeEventDraft(
            type: MetricEventType.recorded, steward: StewardID(unchecked: "st_inbox"),
            actor: .system,
            payload: try CanonicalJSON.decode(
                JSONValue.self,
                from: try CanonicalJSON.encode(
                    MetricRecorded(metric: charter.metric.name, value: 0.25)))))

    let window = try await workspace.outcomeWindow(steward: "st_inbox")
    #expect(window.days == 3 && window.fromCharter && window.text == "the last 3 days")
    #expect(window.measured == 1 && window.missed == 1)
    #expect(window.missedText == "missed its target on 1 of 1 measured day in the last 3 days")
    let outcome = try await workspace.outcome(steward: "st_inbox")
    #expect(outcome.trend.count == 3 && outcome.window?.missed == 1)
    #expect(outcome.window?.start == window.start)
    let metrics = try await workspace.metricStatuses(steward: "st_inbox")
    #expect(metrics.first?.trend.map(\.start) == outcome.trend.map(\.start))
    let findings = try await workspace.overviewFindings(steward: "st_inbox")
    #expect(
        findings.contains {
            $0.kind == "negative" && $0.text == "\(charter.metric.name) \(window.missedText ?? "")"
        })

    // Every day measured reads as N of the last M days; no period means 7 days.
    let full = Workspace.window(
        steward: "st_inbox", metric: Metric(name: "m", unit: "", direction: .up, target: 1),
        start: .now, end: .now, values: [0, 2, 0, 0, 2, 2, 0])
    #expect(full.days == 7 && !full.fromCharter)
    #expect(full.missedText == "missed its target on 4 of the last 7 days")
    charter.metric.windowDays = 0
    #expect(charter.validate().map(\.path) == ["metric.windowDays"])
}
