import AryaAdapters
import AryaCore
import AryaLedger
import Testing

@testable import AryaRuntime

private func measured() -> FakeScript.Run {
    var result = triageResult
    if case .object(var fields) = result {
        fields["measurements"] = [
            ["metric": "triage_minutes", "value": 4.5], ["metric": "reopened", "value": 0],
        ]
        result = .object(fields)
    }
    return FakeScript.Run(result: result)
}

@Test func liveRunRecordsEachMeasurementAsAMetric() async throws {
    let harness = RunHarness(measured())
    let outcome = try await harness.start()
    let events = try await harness.sink.events(from: 1)
    let metrics = events.filter { $0.type == MetricEventType.recorded }
    #expect(metrics.count == 2)
    let first = try Payload.decode(MetricRecorded.self, metrics[0].payload)
    #expect(first == MetricRecorded(metric: "triage_minutes", value: 4.5))
    #expect(
        metrics.allSatisfy {
            $0.draft.run == outcome.run
                && $0.draft.actor
                    == .steward(
                        StewardID(unchecked: "st_triage"))
        })
    // Metrics land after the decisions and before the run ends.
    let types = try await harness.types()
    let metricAt = try #require(types.firstIndex(of: "metric.recorded"))
    #expect(types[metricAt - 1] == "run.decision")
    #expect(types.last == "run.finished")
}

@Test func rehearsalRecordsNoMetrics() async throws {
    let harness = RunHarness(measured())
    _ = try await harness.start(.rehearsal(CaseContext()))
    #expect(try await harness.last(MetricEventType.recorded) == nil)
}

@Test func metricPayloadMatchesTheLedgerShape() throws {
    let json = try CanonicalJSON.jsonValue(MetricRecorded(metric: "reopened", value: 1))
    #expect(json == ["metric": "reopened", "value": 1])
    #expect(MetricRecorded.type.rawValue == "metric.recorded")
}
