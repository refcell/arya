import Foundation

/// An in-process fake adapter driven by a ``FakeScript``. Deterministic; every test that needs
/// an adapter uses it (or the `arya-fake-adapter` binary, which runs the same server).
///
/// It is a real ``AdapterConnection`` over an ``InMemoryPipe``, so the host-side code paths
/// are the same as for a process adapter.
public final class FakeAdapter: Adapter {
    /// The connection to the in-process server.
    public let connection: AdapterConnection

    public init(
        script: FakeScript, timeouts: ConnectionTimeouts = .standard,
        idleClock: any SleepClock = SystemSleepClock(), pace: Int = 0
    ) {
        let (transport, endpoint) = InMemoryPipe.make()
        let server = FakeAdapterServer(script: script, endpoint: endpoint, pace: pace)
        Task { await server.serve() }
        connection = AdapterConnection(
            transport: transport, timeouts: timeouts, idleClock: idleClock)
    }

    public var updates: AsyncStream<AdapterUpdate> { connection.updates }

    public func initialize(_ params: InitializeParams) async throws(AdapterError)
        -> InitializeResult
    {
        try await connection.initialize(params)
    }

    public func start(_ params: RunStartParams) async throws(AdapterError) -> RunStartResult {
        try await connection.start(params)
    }

    public func send(_ params: RunSendParams) async throws(AdapterError) {
        try await connection.send(params)
    }

    public func stop(_ params: RunStopParams) async throws(AdapterError) {
        try await connection.stop(params)
    }

    public func transcript(_ params: SessionParams) async throws(AdapterError)
        -> TranscriptResult
    {
        try await connection.transcript(params)
    }

    public func cost(_ params: SessionParams) async throws(AdapterError) -> CostResult {
        try await connection.cost(params)
    }

    public func shutdown() async throws(AdapterError) {
        try await connection.shutdown()
    }

    public func answer(_ id: RPCID, _ result: HostAskResult) async throws(AdapterError) {
        try await connection.answer(id, result)
    }

    public func answerDelegation(_ id: RPCID, _ result: HostDelegateResult)
        async throws(AdapterError)
    {
        try await connection.answerDelegation(id, result)
    }
}

extension AdapterConnection {
    /// Starts an adapter process and connects to it.
    public static func launch(
        _ command: AdapterCommand, stderr: any StderrSink = StderrBuffer(),
        timeouts: ConnectionTimeouts = .standard
    ) throws(AdapterError) -> AdapterConnection {
        let transport = try ProcessTransport.launch(command, stderr: stderr)
        return AdapterConnection(transport: transport, timeouts: timeouts)
    }
}
