import Foundation

/// The direction of a recorded message, from arya's point of view.
public enum WireDirection: String, Sendable, Hashable, Codable {
    /// arya wrote it to the adapter.
    case sent
    /// arya read it from the adapter.
    case received
}

/// Who wrote a recorded line.
public enum WireSource: String, Sendable, Hashable, Codable {
    /// The runtime, through a call on ``Adapter``.
    case host
    /// The connection on its own: the idle-timeout `run/stop` and replies to requests the host
    /// does not serve. Replay produces these itself.
    case connection
    /// The adapter.
    case adapter
}

/// One line that crossed the connection, exactly as written or read.
public struct WireRecord: Sendable, Hashable {
    public var direction: WireDirection
    public var source: WireSource
    /// The bytes of the line, without its newline.
    public var line: Data
    /// The decoded message, or `nil` when the line was not a valid JSON-RPC message.
    public var message: RPCMessage?

    /// A record; `source` defaults to `.host` for sent lines and `.adapter` for received ones.
    public init(
        direction: WireDirection, source: WireSource? = nil, line: Data, message: RPCMessage?
    ) {
        self.direction = direction
        self.source = source ?? (direction == .sent ? .host : .adapter)
        self.line = line
        self.message = message
    }

    /// A record rebuilt from stored bytes, decoding the message again.
    public init(direction: WireDirection, source: WireSource? = nil, line: Data) {
        self.init(
            direction: direction, source: source, line: line,
            message: try? LineCodec.decode(line))
    }
}

/// Something the host learns from an adapter, in the order it happened.
///
/// Every line in both directions arrives first as `.wire`, so a recorder that stores `.wire`
/// updates keeps the full conversation in order. The typed cases follow the `.wire` update of
/// the message they come from.
public enum AdapterUpdate: Sendable, Hashable {
    case wire(WireRecord)
    /// A `run/event` notification.
    case event(RunEventParams)
    /// The `run/result` notification.
    case result(RunResultParams)
    /// A `host/ask` request; reply with ``Adapter/answer(_:_:)``.
    case ask(id: RPCID, HostAskParams)
    /// A `host/delegate` request; reply with ``Adapter/answerDelegation(_:_:)`` when the child
    /// run ends.
    case delegate(id: RPCID, HostDelegateParams)
    /// A stdout line or message that broke the protocol.
    case protocolError(RPCError)
    /// No message arrived within the run's timeout; arya sent `run/stop` with reason
    /// `timeout`.
    case timedOut
    /// The adapter is gone. Always the last update.
    case exited(AdapterExit)
}

/// The host's view of one adapter: typed requests and an ordered stream of updates.
///
/// Implemented by ``AdapterConnection`` (over a process or an in-memory pipe) and by
/// ``ReplayAdapter``.
public protocol Adapter: Sendable {
    /// Every update, ending with `.exited`. Iterate it once.
    var updates: AsyncStream<AdapterUpdate> { get }
    func initialize(_ params: InitializeParams) async throws(AdapterError) -> InitializeResult
    func start(_ params: RunStartParams) async throws(AdapterError) -> RunStartResult
    func send(_ params: RunSendParams) async throws(AdapterError)
    func stop(_ params: RunStopParams) async throws(AdapterError)
    func transcript(_ params: SessionParams) async throws(AdapterError) -> TranscriptResult
    func cost(_ params: SessionParams) async throws(AdapterError) -> CostResult
    /// Sends `shutdown`, closes stdin, and waits for the adapter to exit.
    func shutdown() async throws(AdapterError)
    /// Answers a `host/ask` request.
    func answer(_ id: RPCID, _ result: HostAskResult) async throws(AdapterError)
    /// Answers a `host/delegate` request.
    func answerDelegation(_ id: RPCID, _ result: HostDelegateResult) async throws(AdapterError)
}
