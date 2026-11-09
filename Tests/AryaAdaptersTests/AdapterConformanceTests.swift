import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// The adapter protocol, checked against a real adapter process: `ARYA_ADAPTER_CMD` when set,
/// otherwise `arya-fake-adapter`. Run one adapter with
/// `ARYA_ADAPTER_CMD="path/to/adapter args" just test AdapterConformance`.
@Suite struct AdapterConformance {
    static let input = "conformance: reply with an empty result"

    func connect() async throws -> (AdapterConnection, InitializeResult) {
        let adapter = try AdapterUnderTest.launch()
        let hello = try await adapter.initialize(InitializeParams(client: Sample.client))
        return (adapter, hello)
    }

    @Test func handshake() async throws {
        let (adapter, hello) = try await connect()
        #expect(hello.protocolVersion == adapterProtocolVersion)
        #expect(!hello.adapter.name.isEmpty)
        #expect(Set(hello.capabilities.effort).isSubset(of: ["low", "medium", "high"]))
        try await adapter.shutdown()
    }

    @Test func unsupportedVersionIsRejected() async throws {
        let adapter = try AdapterUnderTest.launch()
        let code = await code {
            try await adapter.initialize(
                InitializeParams(protocolVersion: 999, client: Sample.client))
        }
        #expect(code == RPCErrorCode.unsupportedProtocol)
        try await adapter.shutdown()
    }

    @Test func oneRunPerProcess() async throws {
        let (adapter, _) = try await connect()
        _ = try await adapter.start(Sample.start(Self.input, run: "run_c1"))
        let code = await code { try await adapter.start(Sample.start(Self.input, run: "run_c2")) }
        #expect(code == RPCErrorCode.busy)
        try await adapter.shutdown()
    }

    @Test func eventsAreOrderedAndResultIsSentOnce() async throws {
        let (adapter, _) = try await connect()
        let session = try await adapter.start(Sample.start(Self.input)).session
        var updates = await collect(adapter, until: \.isResult)
        _ = try await adapter.cost(SessionParams(session: session))
        try await adapter.shutdown()
        updates += await collect(adapter)
        let events = updates.compactMap(\.event)
        #expect(events.map(\.seq) == Array(1..<(events.count + 1)))
        #expect(events.allSatisfy { $0.session == session })
        #expect(updates.compactMap(\.result).count == 1)
        #expect(updates.compactMap(\.result).first?.session == session)
    }

    @Test func stopYieldsAResultWithinTenSeconds() async throws {
        let (adapter, _) = try await connect()
        let session = try await adapter.start(Sample.start(Self.input)).session
        let clock = ContinuousClock()
        let began = clock.now
        try await adapter.stop(RunStopParams(session: session, reason: .user))
        let updates = await collect(adapter, until: \.isResult)
        #expect(clock.now - began < .seconds(10))
        let result = try #require(updates.compactMap(\.result).first)
        #expect([RunStatus.stopped, .completed].contains(result.status))
        try await adapter.shutdown()
    }

    @Test func errorCodes() async throws {
        let (adapter, _) = try await connect()
        _ = try await adapter.start(Sample.start(Self.input))
        let unknownSession = await code { try await adapter.cost(SessionParams(session: "nope")) }
        let unknownMethod = await code { try await adapter.request("run/unknown") }
        #expect(unknownSession == RPCErrorCode.unknownSession)
        #expect(unknownMethod == RPCErrorCode.methodNotFound)
        try await adapter.shutdown()
    }

    @Test func shutdownExitsCleanly() async throws {
        let (adapter, _) = try await connect()
        try await adapter.shutdown()
        #expect(await adapter.waitForExit() == .exited(0))
    }
}
