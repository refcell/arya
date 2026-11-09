import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// What a host does with an adapter in these tests: initialize, start, answer every question
/// with "yes" and every delegation with ``Sample/childOutcome``, wait for the result, ask the
/// cost, and shut down. Returns every update.
func drive(_ adapter: any Adapter, input: String = "triage ISSUE-1") async throws
    -> [AdapterUpdate]
{
    _ = try await adapter.initialize(InitializeParams(client: Sample.client))
    let session = try await adapter.start(Sample.start(input)).session
    var updates: [AdapterUpdate] = []
    var iterator = adapter.updates.makeAsyncIterator()
    while let update = await iterator.next() {
        updates.append(update)
        if case .ask(let id, _) = update {
            try await adapter.answer(id, HostAskResult(answer: "yes"))
        }
        if case .delegate(let id, _) = update {
            try await adapter.answerDelegation(id, Sample.childOutcome)
        }
        if update.isResult || update.exit != nil { break }
    }
    if updates.last?.exit == nil {
        _ = try? await adapter.cost(SessionParams(session: session))
        try await adapter.shutdown()
        while let update = await iterator.next() { updates.append(update) }
    }
    return updates
}

/// Replaying a live session with the same calls publishes the same updates, in order.
@discardableResult
func expectReplayMatches(_ script: FakeScript, timeouts: ConnectionTimeouts = Sample.timeouts)
    async throws -> [AdapterUpdate]
{
    let live = FakeAdapter(script: script, timeouts: timeouts)
    let recorded = try await drive(live)
    let exit = try #require(recorded.last?.exit)
    let replay = ReplayAdapter(records: recorded.compactMap(\.wire), exit: exit)
    let replayed = try await drive(replay)
    #expect(replayed == recorded)
    #expect(await replay.isFinished)
    return recorded
}

@Test func replayReproducesARun() async throws {
    try await expectReplayMatches(Sample.script)
}

@Test func replayReproducesHostAsk() async throws {
    try await expectReplayMatches(
        Sample.script(FakeScript.Response(steps: [.ask(question: "Go?", to: nil)], result: [:])))
}

@Test func replayReproducesHostDelegate() async throws {
    let step = FakeScript.Step.delegate(id: "c1", title: "Draft", input: "Draft the reply.")
    try await expectReplayMatches(Sample.script(FakeScript.Response(steps: [step], result: [:])))
}

@Test func replayReproducesACrash() async throws {
    try await expectReplayMatches(
        Sample.script(
            FakeScript.Response(
                events: [RunEvent(.thinking(text: "x"))], steps: [.crash(exitCode: 3)])))
}

@Test func replayReproducesAnIdleTimeout() async throws {
    var timeouts = Sample.timeouts
    timeouts.idle = .milliseconds(500)
    let updates = try await expectReplayMatches(
        Sample.script(FakeScript.Response(steps: [.hang])), timeouts: timeouts)
    #expect(updates.contains(.timedOut))
    #expect(updates.compactMap(\.wire).contains { $0.source == .connection })
}

@Test func replayRebuildsRecordsFromBytes() async throws {
    let recorded = try await drive(FakeAdapter(script: Sample.script, timeouts: Sample.timeouts))
    let stored = recorded.compactMap(\.wire).map { record in
        WireRecord(direction: record.direction, source: record.source, line: record.line)
    }
    let replayed = try await drive(ReplayAdapter(records: stored, exit: .exited(0)))
    #expect(replayed == recorded)
}

@Test func replayFailsLoudlyOnDivergence() async throws {
    let recorded = try await drive(FakeAdapter(script: Sample.script, timeouts: Sample.timeouts))
    let replay = ReplayAdapter(records: recorded.compactMap(\.wire), exit: .exited(0))
    _ = try await replay.initialize(InitializeParams(client: Sample.client))
    do {
        _ = try await replay.start(Sample.start("a different input"))
        Issue.record("expected a divergence")
    } catch {
        guard case .replayDivergence(let expected, let actual) = error else { throw error }
        #expect(expected.contains("triage ISSUE-1"))
        #expect(actual.contains("a different input"))
    }
}

@Test func replayPastTheEndFails() async throws {
    let replay = ReplayAdapter(records: [], exit: .exited(0))
    await #expect(throws: AdapterError.exited(.exited(0))) {
        try await replay.initialize(InitializeParams(client: Sample.client))
    }
}

@Test func replayRunsFromLedgerPayloads() async throws {
    var timeouts = Sample.timeouts
    timeouts.idle = .milliseconds(500)
    let script = Sample.script(FakeScript.Response(steps: [.stdout("not json"), .hang]))
    let recorded = try await drive(FakeAdapter(script: script, timeouts: timeouts))
    let payloads = recorded.compactMap(\.wire).map(\.ledgerPayload)
    #expect(payloads.contains { $0["raw"] == "not json" })
    #expect(payloads.contains { $0["source"] == "connection" })
    let records = try payloads.map { try #require(WireRecord(ledgerPayload: $0)) }
    let exit = try #require(recorded.last?.exit)
    #expect(try await drive(ReplayAdapter(records: records, exit: exit)) == recorded)
    let fromPayloads = try #require(ReplayAdapter(ledgerPayloads: payloads, exit: exit))
    #expect(try await drive(fromPayloads) == recorded)
    #expect(ReplayAdapter(ledgerPayloads: payloads + [["direction": "sideways"]]) == nil)
}
