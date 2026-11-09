import Foundation

/// The adapter's side of a line connection: lines from the host in, lines to the host out.
/// ``FakeAdapterServer`` runs on one of these, in process or over stdio.
public protocol AdapterEndpoint: Sendable {
    /// Lines from the host, without newlines; finishes when the host closes stdin.
    var incoming: AsyncStream<Data> { get }
    /// Writes one line to the host (the newline is included in `line`).
    func write(_ line: Data) async
    /// Ends the connection as the adapter process would by exiting.
    func close(_ exit: AdapterExit) async
}

/// A small thread-safe box for state shared with callbacks that are not async.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// An in-memory connection between a host and an in-process adapter.
public enum InMemoryPipe {
    /// A connected pair: give `transport` to an ``AdapterConnection`` and `endpoint` to the
    /// in-process adapter.
    public static func make() -> (transport: InMemoryTransport, endpoint: InMemoryEndpoint) {
        let toHost = AsyncStream.makeStream(of: TransportInput.self, bufferingPolicy: .unbounded)
        let toAdapter = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let state = Locked(PipeState())
        let transport = InMemoryTransport(
            input: toHost.stream, hostOut: toHost.continuation, adapterIn: toAdapter.continuation,
            state: state)
        let endpoint = InMemoryEndpoint(
            incoming: toAdapter.stream, hostOut: toHost.continuation,
            adapterIn: toAdapter.continuation, state: state)
        return (transport, endpoint)
    }
}

struct PipeState {
    var ended = false
}

/// The host's side of an ``InMemoryPipe``.
public final class InMemoryTransport: AdapterTransport {
    public let input: AsyncStream<TransportInput>
    private let hostOut: AsyncStream<TransportInput>.Continuation
    private let adapterIn: AsyncStream<Data>.Continuation
    private let state: Locked<PipeState>

    init(
        input: AsyncStream<TransportInput>, hostOut: AsyncStream<TransportInput>.Continuation,
        adapterIn: AsyncStream<Data>.Continuation, state: Locked<PipeState>
    ) {
        self.input = input
        self.hostOut = hostOut
        self.adapterIn = adapterIn
        self.state = state
    }

    public func write(_ line: Data) async throws {
        if state.withLock({ $0.ended }) { throw AdapterError.writeFailed("adapter closed") }
        var bytes = line
        if bytes.last == 0x0A { bytes.removeLast() }
        adapterIn.yield(bytes)
    }

    public func closeInput() async {
        adapterIn.finish()
    }

    /// Simulates SIGTERM: the adapter's input closes and the connection ends at once.
    public func terminate(grace: Duration) async {
        // Record the signal before closing the adapter's input, or the adapter could see
        // end-of-input and report a clean exit first.
        end(.signaled(SIGTERM), state: state, hostOut: hostOut)
        adapterIn.finish()
    }
}

/// The adapter's side of an ``InMemoryPipe``.
public final class InMemoryEndpoint: AdapterEndpoint {
    public let incoming: AsyncStream<Data>
    private let hostOut: AsyncStream<TransportInput>.Continuation
    private let adapterIn: AsyncStream<Data>.Continuation
    private let state: Locked<PipeState>

    init(
        incoming: AsyncStream<Data>, hostOut: AsyncStream<TransportInput>.Continuation,
        adapterIn: AsyncStream<Data>.Continuation, state: Locked<PipeState>
    ) {
        self.incoming = incoming
        self.hostOut = hostOut
        self.adapterIn = adapterIn
        self.state = state
    }

    public func write(_ line: Data) async {
        if state.withLock({ $0.ended }) { return }
        var splitter = LineSplitter()
        for piece in splitter.append(line) { hostOut.yield(.line(piece)) }
        if let rest = splitter.finish() { hostOut.yield(.line(rest)) }
    }

    public func close(_ exit: AdapterExit) async {
        adapterIn.finish()
        end(exit, state: state, hostOut: hostOut)
    }
}

private func end(
    _ exit: AdapterExit, state: Locked<PipeState>,
    hostOut: AsyncStream<TransportInput>.Continuation
) {
    let first = state.withLock { pipe in
        defer { pipe.ended = true }
        return !pipe.ended
    }
    guard first else { return }
    hostOut.yield(.ended(exit))
    hostOut.finish()
}
