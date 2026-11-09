import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

private let draft = FakeScript.Step.delegate(
    id: "c1", title: "Draft the refund reply", input: "Draft a reply to MSG-203.")

/// Runs a script with one `delegate` step, answering it with `outcome`. Returns the updates
/// and the delegation arya was asked to run.
private func runDelegation(
    _ outcome: HostDelegateResult, clock: ManualClock? = nil, idleTicks: Int = 0
) async throws -> ([AdapterUpdate], HostDelegateParams?) {
    var timeouts = Sample.timeouts
    if clock != nil { timeouts.idle = .seconds(60) }
    let adapter = FakeAdapter(
        script: Sample.script(FakeScript.Response(steps: [draft], result: [:])),
        timeouts: timeouts, idleClock: clock ?? ManualClock())
    _ = try await adapter.start(Sample.start("x"))
    var updates: [AdapterUpdate] = []
    var asked: HostDelegateParams?
    for await update in adapter.updates {
        updates.append(update)
        if case .delegate(let id, let params) = update {
            asked = params
            var ticks = 0
            while ticks < idleTicks, let clock, await clock.tick() { ticks += 1 }
            #expect(ticks == idleTicks, "the idle timer stopped while the child ran")
            try? await adapter.answerDelegation(id, outcome)
        }
        if update.isResult { break }
    }
    return (updates, asked)
}

private func delegatedDetails(_ updates: [AdapterUpdate]) -> [String?] {
    updates.compactMap(\.event).compactMap { params in
        if case .status(let state, let detail) = params.event.body, state == "delegated" {
            return detail
        }
        return nil
    }
}

@Test func delegateStepWaitsForTheChildAndReportsHowItEnded() async throws {
    let (updates, asked) = try await runDelegation(Sample.childOutcome)
    let params = try #require(asked)
    #expect(params.id == "c1")
    #expect(params.title == "Draft the refund reply")
    #expect(params.input == "Draft a reply to MSG-203.")
    #expect(params.session.hasPrefix("fake-"))
    #expect(delegatedDetails(updates) == ["completed run_child"])
    #expect(updates.compactMap(\.result).first?.status == .completed)
}

@Test func refusedDelegationIsReportedAndTheRunCarriesOn() async throws {
    let (updates, _) = try await runDelegation(.refused("depth limit"))
    #expect(delegatedDetails(updates) == ["refused: depth limit"])
    #expect(updates.compactMap(\.result).first?.status == .completed)
}

@Test func idleTimerPausesWhileADelegationIsOpen() async throws {
    let (updates, _) = try await runDelegation(
        Sample.childOutcome, clock: ManualClock(), idleTicks: 3)
    #expect(!updates.contains(.timedOut))
    #expect(delegatedDetails(updates) == ["completed run_child"])
}

@Test func delegateStepRoundTripsInAScript() throws {
    let json: JSONValue = [
        "delegate": ["id": "c1", "title": "Draft the refund reply", "input": "Draft a reply."]
    ]
    let step = try json.decode(FakeScript.Step.self)
    #expect(step == .delegate(id: "c1", title: "Draft the refund reply", input: "Draft a reply."))
    #expect(try JSONValue(encoding: step) == json)
}

@Test func delegateRequestMatchesAResultDelegation() throws {
    let json: JSONValue = [
        "session": "s1", "id": "c1", "title": "Draft", "input": "Draft a reply.",
        "adapter": "reviewer", "effort": "low", "limits": ["maxTurns": 4],
    ]
    let params = try json.decode(HostDelegateParams.self)
    #expect(try JSONValue(encoding: params) == json)
    #expect(
        params.delegation
            == RunResult.Delegation(
                id: "c1", title: "Draft", input: "Draft a reply.", adapter: "reviewer",
                effort: "low", limits: RunLimits(maxTurns: 4)))
}

@Test func refusalOmitsRunAndResult() throws {
    let value = try JSONValue(encoding: HostDelegateResult.refused("depth limit"))
    #expect(value == ["status": "refused", "reason": "depth limit"])
}

@Test func hostWithoutDelegateSupportReadsAsARefusal() async throws {
    // A host from before host/delegate answers it with -32601; the run still finishes.
    let (transport, endpoint) = InMemoryPipe.make()
    let script = Sample.script(FakeScript.Response(steps: [draft], result: [:]))
    let server = FakeAdapterServer(script: script, endpoint: endpoint)
    Task { await server.serve() }
    let connection = AdapterConnection(transport: transport, timeouts: Sample.timeouts)
    _ = try await connection.start(Sample.start("x"))
    var updates: [AdapterUpdate] = []
    for await update in connection.updates {
        updates.append(update)
        if case .delegate(let id, _) = update {
            let error = RPCError(code: RPCErrorCode.methodNotFound, message: "unknown method")
            try await transport.write(
                LineCodec.encode(.response(RPCResponse(id: id, error: error))))
        }
        if update.isResult { break }
    }
    #expect(delegatedDetails(updates) == ["refused: arya did not run the delegation"])
    #expect(updates.compactMap(\.result).first?.status == .completed)
}

@Test func delegationDetailNamesTheRunAndReason() {
    let failed = HostDelegateResult(run: "run_9", status: .failed, reason: "timeout")
    #expect(FakeAdapterServer.describe(failed) == "failed run_9: timeout")
}
