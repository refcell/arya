import AryaAdapters
import AryaCore
import Testing

@testable import AryaRuntime

private let turn = FakeScript.Step.event(RunEvent(.message(role: "assistant", text: "thinking")))

private func limited(_ limits: Limits) -> Charter {
    var charter = triageCharter()
    charter.limits = limits
    return charter
}

private func failure(_ harness: RunHarness) async throws -> (reason: String?, detail: String?) {
    let failed = try #require(try await harness.last("run.failed"))
    return (failed.payload["reason"]?.stringValue, failed.payload["detail"]?.stringValue)
}

@Test func runStopsWhenItUsesMoreTurnsThanAllowed() async throws {
    let harness = RunHarness(
        FakeScript.Run(steps: [turn, turn, turn, turn], result: triageResult))
    let outcome = try await harness.start(charter: limited(Limits(maxTurns: 2)))
    #expect(outcome.phase == .failed(.budget))
    let (reason, detail) = try await failure(harness)
    #expect(reason == "budget")
    #expect(detail == "max_turns: 3 > 2")
    // A stopped run proposes nothing.
    #expect(try await !harness.types().contains("action.proposed"))
}

@Test func runStopsWhenItCostsMoreThanAllowed() async throws {
    let harness = RunHarness(
        FakeScript.Run(
            steps: [toolCall, turn], result: triageResult,
            cost: CostResult(inputTokens: 10, outputTokens: 5, costMicros: 5_000)))
    let outcome = try await harness.start(charter: limited(Limits(maxCostMicros: 4_000)))
    #expect(outcome.phase == .failed(.budget))
    let failed = try #require(try await harness.last("run.failed"))
    #expect(failed.payload["detail"] == "max_cost_micros: 5000 > 4000")
    #expect(failed.payload["cost"]?["costMicros"] == 5000)
}

@Test func runWithinBudgetFinishes() async throws {
    let harness = RunHarness(
        FakeScript.Run(
            steps: [turn, turn], result: triageResult, cost: CostResult(costMicros: 4_000)))
    let outcome = try await harness.start(
        charter: limited(Limits(maxTurns: 2, maxCostMicros: 4_000)))
    #expect(outcome.phase == .finished(.completed))
}

@Test func runPastItsTimeoutIsStoppedAndFails() async throws {
    let harness = RunHarness(
        FakeScript.Run(steps: [.sleep(milliseconds: 2_000)], result: triageResult),
        secondsUnit: .milliseconds(20))
    let outcome = try await harness.start(charter: limited(Limits(timeoutSeconds: 1)))
    #expect(outcome.phase == .failed(.timeout))
    let (reason, detail) = try await failure(harness)
    #expect(reason == "timeout")
    #expect(detail == "ran past timeoutSeconds: 1")
}
