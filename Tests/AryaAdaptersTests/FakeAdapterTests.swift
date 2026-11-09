import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

@Test func fakeAdapterRunsAScriptedRun() async throws {
    let adapter = FakeAdapter(script: Sample.script, timeouts: Sample.fast)
    let hello = try await adapter.initialize(InitializeParams(client: Sample.client))
    #expect(hello.capabilities == FakeScript.defaultCapabilities)
    let started = try await adapter.start(Sample.start("triage ISSUE-1"))
    #expect(started.session == "fake-run_1")
    let updates = await collect(adapter, until: \.isResult)
    let events = updates.compactMap(\.event)
    #expect(events.map(\.seq) == [1, 2])
    #expect(events.last?.event.body == .message(role: "assistant", text: "It is a bug."))
    let result = try #require(updates.compactMap(\.result).first)
    #expect(result.status == .completed)
    #expect(try result.decodedResult().decisions.map(\.choice) == ["bug"])
    let cost = try await adapter.cost(SessionParams(session: started.session))
    #expect(cost.costMicros == 42)
    try await adapter.shutdown()
    #expect(await adapter.connection.waitForExit() == .exited(0))
}

@Test func everyMessageIsRecordedInOrder() async throws {
    let adapter = FakeAdapter(script: Sample.script, timeouts: Sample.fast)
    _ = try await adapter.initialize(InitializeParams(client: Sample.client))
    _ = try await adapter.start(Sample.start("triage ISSUE-1"))
    var updates = await collect(adapter, until: \.isResult)
    try await adapter.shutdown()
    updates += await collect(adapter)
    let wire = updates.compactMap(\.wire)
    let summary = wire.map { record in
        "\(record.direction.rawValue) \(record.message?.method ?? "response")"
    }
    #expect(
        summary == [
            "sent initialize", "received response", "sent run/start", "received response",
            "received run/event", "received run/event", "received run/result", "sent shutdown",
            "received response",
        ])
    #expect(wire.allSatisfy { $0.line.last != 0x0A })
    #expect(updates.last?.exit == .exited(0))
    // Every typed update follows the wire record it came from.
    let firstEvent = try #require(updates.firstIndex { $0.event != nil })
    #expect(updates[firstEvent - 1].wire?.message?.method == RPCMethod.runEvent)
}

@Test func secondRunOnOneProcessIsBusy() async throws {
    let adapter = FakeAdapter(script: Sample.script, timeouts: Sample.fast)
    _ = try await adapter.start(Sample.start("triage ISSUE-1"))
    await #expect(
        throws: AdapterError.rpc(
            RPCError(code: -32005, message: "busy: this process already has a run"))
    ) {
        try await adapter.start(Sample.start("triage ISSUE-1", run: "run_2"))
    }
}

@Test func unsupportedProtocolIsRejected() async throws {
    let adapter = FakeAdapter(script: Sample.script, timeouts: Sample.fast)
    do {
        _ = try await adapter.initialize(
            InitializeParams(protocolVersion: 99, client: Sample.client))
        Issue.record("expected -32001")
    } catch {
        guard case .rpc(let rpc) = error else { throw error }
        #expect(rpc.code == RPCErrorCode.unsupportedProtocol)
    }
}

@Test func unmatchedInputAndStartErrorsFail() async throws {
    let script = FakeScript(responses: [
        "boom": FakeScript.Response(startError: RPCError(code: -32004, message: "harness crashed"))
    ])
    for text in ["boom", "no such input"] {
        let adapter = FakeAdapter(script: script, timeouts: Sample.fast)
        do {
            _ = try await adapter.start(Sample.start(text))
            Issue.record("expected -32004")
        } catch {
            guard case .rpc(let rpc) = error else { throw error }
            #expect(rpc.code == RPCErrorCode.harnessFailure)
        }
    }
}

@Test func unknownSessionAndMissingCapability() async throws {
    var script = Sample.script
    script.capabilities.send = false
    let adapter = FakeAdapter(script: script, timeouts: Sample.fast)
    _ = try await adapter.start(Sample.start("triage ISSUE-1"))
    let codes = [
        await code { try await adapter.cost(SessionParams(session: "nope")) },
        await code {
            try await adapter.send(
                RunSendParams(session: "fake-run_1", message: HumanMessage(text: "hi")))
        },
    ]
    #expect(codes == [RPCErrorCode.unknownSession, RPCErrorCode.capabilityNotSupported])
}

/// The JSON-RPC error code `body` fails with, or nil.
func code(_ body: () async throws -> some Any) async -> Int? {
    do {
        _ = try await body()
        return nil
    } catch AdapterError.rpc(let rpc) {
        return rpc.code
    } catch {
        return nil
    }
}

@Test func hostAskRoundTrips() async throws {
    let script = Sample.script(
        FakeScript.Response(
            steps: [.ask(question: "Assign to Alex?", to: "person:alex")], result: [:]))
    let adapter = FakeAdapter(script: script, timeouts: Sample.fast)
    _ = try await adapter.start(Sample.start("anything"))
    var answered: [RunEventParams] = []
    for await update in adapter.updates {
        if case .ask(let id, let params) = update {
            #expect(params.question == "Assign to Alex?")
            #expect(params.to == "person:alex")
            try await adapter.answer(id, HostAskResult(answer: "yes"))
        }
        if let event = update.event { answered.append(event) }
        if update.isResult { break }
    }
    #expect(answered.map(\.event.body) == [.message(role: "human", text: "yes")])
}

@Test func sendAndTranscript() async throws {
    let script = Sample.script(FakeScript.Response(steps: [.hang]))
    let adapter = FakeAdapter(script: script, timeouts: Sample.fast)
    let session = try await adapter.start(Sample.start("x")).session
    try await adapter.send(RunSendParams(session: session, message: HumanMessage(text: "Use bug.")))
    let transcript = try await adapter.transcript(SessionParams(session: session))
    #expect(transcript.events.map(\.body) == [.message(role: "human", text: "Use bug.")])
    try await adapter.stop(RunStopParams(session: session, reason: .user))
    let updates = await collect(adapter, until: \.isResult)
    #expect(updates.compactMap(\.result).first?.status == .stopped)
}

@Test func crashEndsTheConnectionWithoutAResult() async throws {
    let script = Sample.script(
        FakeScript.Response(
            events: [RunEvent(.thinking(text: "hm"))], steps: [.crash(exitCode: 3)]))
    let adapter = FakeAdapter(script: script, timeouts: Sample.fast)
    let session = try await adapter.start(Sample.start("x")).session
    let updates = await collect(adapter)
    #expect(updates.compactMap(\.result).isEmpty)
    #expect(updates.last?.exit == .exited(3))
    await #expect(throws: AdapterError.exited(.exited(3))) {
        try await adapter.cost(SessionParams(session: session))
    }
}

@Test func nonJSONStdoutIsAProtocolError() async throws {
    let script = Sample.script(FakeScript.Response(steps: [.stdout("hello, not json")]))
    let adapter = FakeAdapter(script: script, timeouts: Sample.fast)
    _ = try await adapter.start(Sample.start("x"))
    let updates = await collect(adapter, until: \.isResult)
    let errors = updates.compactMap { update -> RPCError? in
        if case .protocolError(let error) = update { return error }
        return nil
    }
    #expect(errors.map(\.code) == [RPCErrorCode.parseError])
    #expect(
        updates.contains {
            $0.wire?.message == nil && $0.wire?.line == Data("hello, not json".utf8)
        })
}

@Test func idleTimeoutStopsTheRun() async throws {
    let script = Sample.script(FakeScript.Response(steps: [.hang]))
    var timeouts = Sample.fast
    timeouts.idle = .milliseconds(100)
    let adapter = FakeAdapter(script: script, timeouts: timeouts)
    _ = try await adapter.start(Sample.start("x"))
    let updates = await collect(adapter, until: \.isResult)
    #expect(updates.contains(.timedOut))
    let stop = updates.compactMap(\.wire).first { $0.message?.method == RPCMethod.runStop }
    #expect(stop?.message.flatMap(requestParams)?["reason"] == "timeout")
    #expect(updates.compactMap(\.result).first?.status == .stopped)
}

@Test func adapterIgnoringStopIsTerminated() async throws {
    let script = Sample.script(FakeScript.Response(steps: [.hang], ignoreStop: true))
    var timeouts = Sample.fast
    timeouts.idle = .milliseconds(100)
    let adapter = FakeAdapter(script: script, timeouts: timeouts)
    _ = try await adapter.start(Sample.start("x"))
    let updates = await collect(adapter)
    #expect(updates.contains(.timedOut))
    #expect(updates.compactMap(\.result).isEmpty)
    #expect(updates.last?.exit == .signaled(SIGTERM))
}

func requestParams(_ message: RPCMessage) -> JSONValue? {
    if case .request(let request) = message { return request.params }
    return nil
}
