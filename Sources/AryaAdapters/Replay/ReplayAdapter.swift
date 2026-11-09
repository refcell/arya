import AryaCore
import Foundation

/// An ``Adapter`` that serves a recorded conversation, for `arya replay`.
///
/// It holds every recorded line in order. Each call must write exactly the next recorded host
/// line (same method, id, and params); then the adapter's recorded lines up to the next host
/// line are published as updates, just as ``AdapterConnection`` would publish them live, and
/// the call returns its recorded response. Lines the connection wrote on its own (source
/// `.connection`: the idle-timeout `run/stop` and replies to unserved requests) are replayed
/// without a call, and a replayed idle `run/stop` publishes `.timedOut`. Anything else the host
/// writes fails loudly with ``AdapterError/replayDivergence(expected:actual:)``.
public actor ReplayAdapter: Adapter {
    public nonisolated let updates: AsyncStream<AdapterUpdate>
    private let continuation: AsyncStream<AdapterUpdate>.Continuation
    private let records: [WireRecord]
    private let recordedExit: AdapterExit
    private var cursor = 0
    private var nextID: Int64 = 1
    private var responses: [RPCID: RPCResponse] = [:]
    private var ended = false

    /// - Parameters:
    ///   - records: every recorded line, in the order it was written or read.
    ///   - exit: how the recorded adapter ended, published as the last update once the
    ///     recording is used up.
    public init(records: [WireRecord], exit: AdapterExit = .exited(0)) {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.records = records
        self.recordedExit = exit
    }

    /// A replay of a run's `run.adapter.event` payloads, in ledger order. Returns `nil` when a
    /// payload is not a wire record (see ``WireRecord/init(ledgerPayload:)``), so a damaged
    /// recording fails before replay starts.
    public init?(ledgerPayloads: [JSONValue], exit: AdapterExit = .exited(0)) {
        var records: [WireRecord] = []
        for payload in ledgerPayloads {
            guard let record = WireRecord(ledgerPayload: payload) else { return nil }
            records.append(record)
        }
        self.init(records: records, exit: exit)
    }

    public func initialize(_ params: InitializeParams) async throws(AdapterError)
        -> InitializeResult
    {
        try call(RPCMethod.initialize, params, as: InitializeResult.self)
    }

    public func start(_ params: RunStartParams) async throws(AdapterError) -> RunStartResult {
        try call(RPCMethod.runStart, params, as: RunStartResult.self)
    }

    public func send(_ params: RunSendParams) async throws(AdapterError) {
        _ = try call(RPCMethod.runSend, params, as: EmptyObject.self)
    }

    public func stop(_ params: RunStopParams) async throws(AdapterError) {
        _ = try call(RPCMethod.runStop, params, as: EmptyObject.self)
    }

    public func transcript(_ params: SessionParams) async throws(AdapterError)
        -> TranscriptResult
    {
        try call(RPCMethod.runTranscript, params, as: TranscriptResult.self)
    }

    public func cost(_ params: SessionParams) async throws(AdapterError) -> CostResult {
        try call(RPCMethod.runCost, params, as: CostResult.self)
    }

    /// Replays `shutdown` if it was recorded; returns quietly if the recorded adapter had
    /// already exited before it.
    public func shutdown() async throws(AdapterError) {
        pump()
        if ended { return }
        _ = try call(RPCMethod.shutdown, EmptyObject(), as: EmptyObject.self)
        pump()
    }

    public func answer(_ id: RPCID, _ result: HostAskResult) async throws(AdapterError) {
        let value: JSONValue
        do {
            value = try JSONValue(encoding: result)
        } catch {
            throw .invalidResponse(method: RPCMethod.hostAsk, detail: "\(error)")
        }
        try expect(.response(RPCResponse(id: id, result: value)))
        pump()
    }

    /// Whether every recorded line has been replayed.
    public var isFinished: Bool { ended }

    // MARK: Plumbing

    private func call<R: Decodable>(
        _ method: String, _ params: some Encodable, as type: R.Type
    ) throws(AdapterError) -> R {
        pump()
        if ended { throw .exited(recordedExit) }
        let paramsValue: JSONValue
        do {
            paramsValue = try JSONValue(encoding: params)
        } catch {
            throw .invalidResponse(method: method, detail: "params do not encode: \(error)")
        }
        let id = RPCID.int(nextID)
        nextID += 1
        try expect(.request(RPCRequest(id: id, method: method, params: paramsValue)))
        pump()
        guard let response = responses.removeValue(forKey: id) else {
            throw .exited(recordedExit)
        }
        let value: JSONValue
        switch response.outcome {
        case .success(let result): value = result
        case .failure(let error): throw .rpc(error)
        }
        do {
            return try value.decode(type)
        } catch {
            throw .invalidResponse(method: method, detail: "\(error)")
        }
    }

    /// Consumes the next record if it is the host writing `message`.
    private func expect(_ message: RPCMessage) throws(AdapterError) {
        let actual = String(decoding: LineCodec.encode(message).dropLast(), as: UTF8.self)
        guard cursor < records.count else {
            throw .replayDivergence(expected: "<end of recording>", actual: actual)
        }
        let record = records[cursor]
        guard record.direction == .sent, record.source == .host, record.message == message
        else {
            let expected = String(decoding: record.line, as: UTF8.self)
            throw .replayDivergence(expected: expected, actual: actual)
        }
        cursor += 1
        continuation.yield(.wire(record))
    }

    /// Publishes recorded lines until the next line the host must write, or the end.
    private func pump() {
        while cursor < records.count {
            let record = records[cursor]
            switch (record.direction, record.source) {
            case (.received, _):
                replayReceived(record)
            case (.sent, .connection):
                replayConnectionLine(record)
            case (.sent, _):
                return
            }
            cursor += 1
        }
        guard !ended else { return }
        ended = true
        continuation.yield(.exited(recordedExit))
        continuation.finish()
    }

    private func replayReceived(_ record: WireRecord) {
        continuation.yield(.wire(record))
        let meaning: Interpretation
        if let message = record.message {
            meaning = Interpretation.of(message)
        } else {
            meaning = Interpretation.of(line: record.line).1
        }
        for update in meaning.updates { continuation.yield(update) }
        if let response = meaning.response { responses[response.id] = response }
    }

    private func replayConnectionLine(_ record: WireRecord) {
        if case .request(let request)? = record.message {
            if case .int(let id) = request.id { nextID = max(nextID, id + 1) }
            if request.method == RPCMethod.runStop { continuation.yield(.timedOut) }
        }
        continuation.yield(.wire(record))
    }
}
