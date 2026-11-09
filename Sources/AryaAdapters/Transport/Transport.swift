import Foundation

/// How an adapter process ended.
public enum AdapterExit: Sendable, Hashable, CustomStringConvertible {
    /// The process exited with this status.
    case exited(Int32)
    /// The process was killed by this signal.
    case signaled(Int32)
    /// An in-process adapter closed its side of the connection.
    case closed

    /// Whether the adapter ended cleanly (status 0 or a closed in-process connection).
    public var isClean: Bool {
        switch self {
        case .exited(let status): status == 0
        case .signaled: false
        case .closed: true
        }
    }

    public var description: String {
        switch self {
        case .exited(let status): "exited with status \(status)"
        case .signaled(let signal): "killed by signal \(signal)"
        case .closed: "closed"
        }
    }
}

/// What a transport reads from the adapter.
public enum TransportInput: Sendable, Hashable {
    /// One complete stdout line, without its newline.
    case line(Data)
    /// The adapter is gone; no more input follows.
    case ended(AdapterExit)
}

/// A line-oriented, two-way connection to an adapter: stdin and stdout of a process, or an
/// in-memory pipe to an in-process adapter.
public protocol AdapterTransport: Sendable {
    /// Lines from the adapter, ending with exactly one `.ended`.
    var input: AsyncStream<TransportInput> { get }
    /// Writes one line (the newline is included in `line`).
    func write(_ line: Data) async throws
    /// Closes the adapter's input (stdin).
    func closeInput() async
    /// Asks the adapter to stop now: SIGTERM, then SIGKILL after `grace` if it is still running.
    func terminate(grace: Duration) async
}

/// Failures of an adapter connection.
public enum AdapterError: Error, Sendable, Hashable {
    /// The adapter answered with a JSON-RPC error.
    case rpc(RPCError)
    /// The adapter went away before answering (`adapter_exited`).
    case exited(AdapterExit)
    /// The adapter did not answer `method` within the request timeout.
    case requestTimedOut(method: String)
    /// The adapter's answer did not decode as the expected type.
    case invalidResponse(method: String, detail: String)
    /// The transport could not write.
    case writeFailed(String)
    /// The executable could not be started.
    case launchFailed(String)
}
