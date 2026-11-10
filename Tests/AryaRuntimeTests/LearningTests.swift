import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private actor OutcomeServer: ToolUpstream {
    var answers: [JSONValue]
    private(set) var calls: [JSONValue] = []

    init(_ answers: [JSONValue]) { self.answers = answers }

    func listTools() async throws -> [JSONValue] { [] }

    func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
        calls.append(arguments)
        return [
            "structuredContent": answers.isEmpty ? ["status": "unknown"] : answers.removeFirst()
        ]
    }

    func close() async {}
}

/// The triage charter with an `outcome` read tool on its tracker binding.
private func checkingCharter() -> Charter {
    var charter = triageCharter()
    charter.bindings[0].read.append("outcome")
    return charter
}

private func ranHarness() async throws -> RunHarness {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    _ = try await harness.start(charter: checkingCharter())
    return harness
}

private func later(_ harness: RunHarness, _ millis: Int64) async throws -> Timestamp {
    let last = try #require(try await harness.sink.events(from: 1).last)
    return last.at.adding(milliseconds: millis)
}

@Test func anExecutedActionIsDueForACheckAfterTheDelay() async throws {
    let harness = try await ranHarness()
    let events = try await harness.sink.events(from: 1)
    #expect(try FollowUps.due(events, now: try await later(harness, 0)).isEmpty)
    let due = try FollowUps.due(events, now: try await later(harness, FollowUps.delay))
    #expect(due.map(\.action.id) == ["a1"])
    #expect(due.first?.target == "tracker:ISSUE-7")
    #expect(due.first?.binding.id == "tracker")
    #expect(due.first?.attempt == 1)
}

@Test func aCheckIsRecordedNormalizedAndSettlesTheAction() async throws {
    let harness = try await ranHarness()
    let server = OutcomeServer([
        [
            "target": "tracker:ISSUE-7", "status": " Resolved ",
            "note": .string(String(repeating: "n", count: 400)),
            "metric": ["name": "minutes_to_label", "value": 12, "delta": -30],
        ]
    ])
    let checker = OutcomeChecker(sink: harness.sink) { _ in server }
    let now = try await later(harness, FollowUps.delay)
    let result = try await checker.check(now: now)
    #expect(result.errors.isEmpty)
    let check = try #require(result.checked.first)
    #expect(check.status == "resolved")
    #expect(check.note?.count == 280)
    #expect(check.metric?.delta == -30)
    #expect(await server.calls.first?["target"] == "tracker:ISSUE-7")
    #expect(await server.calls.first?["action"] == "label")
    let recorded = try #require(try await harness.last("action.checked"))
    #expect(recorded.draft.run != nil)
    #expect(recorded.payload["action"] == "a1")
    let again = try await checker.check(now: now.adding(milliseconds: FollowUps.delay * 5))
    #expect(again.checked.isEmpty)
}

@Test func anOpenTargetIsCheckedAgainUpToTheLimit() async throws {
    let harness = try await ranHarness()
    let server = OutcomeServer([])
    let checker = OutcomeChecker(sink: harness.sink) { _ in server }
    var now = try await later(harness, FollowUps.delay)
    var attempts: [Int] = []
    for _ in 0..<5 {
        attempts += try await checker.check(now: now).checked.map(\.attempt)
        now = now.adding(milliseconds: FollowUps.delay)
    }
    #expect(attempts == [1, 2, 3])
}

@Test func metricChangesAreCreditedToTheActionsInTheirWindow() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    let record = { (value: Double) in
        _ = try await harness.sink.append(
            RuntimeEventDraft(
                type: MetricEventType.recorded, steward: triage, actor: .steward(triage),
                payload: try Payload.encode(
                    MetricRecorded(metric: "triaged_within_1h", value: value))))
    }
    _ = try await harness.lifecycle.create(checkingCharter())
    try await record(0.80)
    _ = try await harness.start()
    try await record(0.90)
    let effects = try Effectiveness.of(triage, in: try await harness.sink.events(from: 1))
    let label = try #require(effects.first { $0.kind == "label" })
    #expect(label.executed == 1)
    #expect(label.credited == 1)
    #expect(abs(label.credit - 0.10) < 1e-9)
    #expect(label.line == "label: metric +0.100 per action (1 executed)")
    // The comment waits for approval, so it never ran and is not scored.
    #expect(!effects.contains { $0.kind == "comment" })
}

@Test func aLowerIsBetterMetricCreditsDrops() {
    var effect = KindEffect(
        kind: "route", executed: 2, failed: 0, resolved: 3, reopened: 1, pending: 0,
        credit: -0.5, credited: 2)
    #expect(effect.successRate == 0.75)
    #expect(effect.line == "route: 3 of 4 resolved, metric -0.250 per action (2 executed)")
    effect.credited = 0
    effect.resolved = 0
    effect.reopened = 0
    #expect(effect.line == "route: no results yet (2 executed)")
}

@Test func liveRunsSeeWhatHasWorked() async throws {
    let harness = try await ranHarness()
    let server = OutcomeServer([["status": "resolved"]])
    _ = try await OutcomeChecker(sink: harness.sink) { _ in server }
        .check(now: try await later(harness, FollowUps.delay))
    _ = try await harness.loop.run(
        RunRequest(steward: triage, input: RunInput(kind: .manual, text: "again")))
    let started = try #require(try await harness.last("run.started"))
    let instructions = started.payload["instructions"]?.stringValue ?? ""
    #expect(instructions.contains("## What has worked\n- label: 1 of 1 resolved (1 executed)"))
}
