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
