import AryaCore
import AryaRuntime
import Testing

@testable import AryaEval

private let triage = StewardID(unchecked: "st_triage")
private let other = StewardID(unchecked: "st_other")
private let day = OutcomeMetrics.dayMillis
private let start: Int64 = 1_767_225_600_000  // a UTC midnight

private func event(
    _ seq: Int, _ type: String, at millis: Int64, steward: StewardID = triage,
    payload: JSONValue = [:]
) -> RuntimeEvent {
    RuntimeEvent(
        seq: seq, id: EventID(unchecked: "ev_\(seq)"), at: Timestamp(millis: millis),
        draft: RuntimeEventDraft(type: type, steward: steward, actor: .system, payload: payload))
}

private let events: [RuntimeEvent] = [
    event(1, "metric.recorded", at: start + 10, payload: ["metric": "triaged", "value": 0.5]),
    event(2, "metric.recorded", at: start + 20, payload: ["metric": "triaged", "value": 1]),
    event(3, "action.executed", at: start + 30),
    event(4, "approval.granted", at: start + 40),
    event(5, "approval.denied", at: start + 50),
    event(6, "action.executed", at: start + 60, steward: other),
    event(7, "run.finished", at: start + 70),
    event(8, "metric.recorded", at: start + 2 * day + 5, payload: ["metric": "triaged"]),
    event(9, "action.failed", at: start + 2 * day + 6),
    event(10, "action.rejected", at: start + 2 * day + 7),
    event(11, "approval.expired", at: start + 2 * day + 8),
    event(
        12, "metric.recorded", at: start + 2 * day + 9, payload: ["metric": "triaged", "value": 0]),
]

@Test func seriesHasFixedContiguousWindows() {
    let series = OutcomeMetrics.series(events, steward: triage)
    #expect(series.windows.map(\.start.millis) == [start, start + day, start + 2 * day])
    #expect(series.means("triaged") == [0.75, nil, 0])
    let first = series.windows[0]
    let stat = first.metrics["triaged"]
    #expect([stat?.count, stat.map { Int($0.sum * 10) }] == [2, 15])
    #expect(stat?.min == 0.5)
    #expect(stat?.max == 1)
    #expect(first.actions == ActionCounts(executed: 1))
    #expect(first.approvals.rate == 0.5)
    #expect(series.windows[1] == MetricWindow(start: Timestamp(millis: start + day)))
    #expect(series.windows[1].approvals.rate == nil)
    #expect(series.windows[2].actions == ActionCounts(failed: 1, rejected: 1))
    #expect(series.windows[2].approvals.rate == 0)
}

@Test func rangePadsAndClips() {
    let range = Timestamp(millis: start - day)...Timestamp(millis: start + day)
    let series = OutcomeMetrics.series(events, steward: triage, range: range)
    #expect(series.windows.count == 3)
    #expect(series.means("triaged") == [nil, 0.75, nil])
}

@Test func hourlyWindowsAndEmptySeries() {
    let hourly = OutcomeMetrics.series(
        Array(events.prefix(5)), steward: triage, windowMillis: 3_600_000)
    #expect(hourly.windows.count == 1)
    #expect(OutcomeMetrics.series(events, steward: StewardID(unchecked: "st_none")).windows.isEmpty)
}

@Test func floorDivisionHandlesNegatives() {
    #expect(OutcomeMetrics.floorDiv(-1, 10) == -1)
    #expect(OutcomeMetrics.floorDiv(10, 10) == 1)
    #expect(OutcomeMetrics.floorDiv(9, 10) == 0)
}
