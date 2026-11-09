import AryaCore
import Foundation

/// The adapter side of the fake adapter: answers the protocol from a ``FakeScript``.
///
/// The same server backs the in-process ``FakeAdapter`` and the `arya-fake-adapter` binary, so
/// tests and the conformance suite exercise one implementation.
public actor FakeAdapterServer {
    private let script: FakeScript
    private let endpoint: any AdapterEndpoint

    private var session: String?
    private var run: FakeScript.Response?
    private var runTask: Task<Void, Never>?
    private var events: [RunEvent] = []
    private var resultSent = false
    private var nextAsk = 1
    private var asks: [RPCID: CheckedContinuation<String?, Never>] = [:]
    private var closed = false

    public init(script: FakeScript, endpoint: any AdapterEndpoint) {
        self.script = script
        self.endpoint = endpoint
    }

    /// Serves until the host closes the connection or sends `shutdown`.
    public func serve() async {
        for await line in endpoint.incoming {
            if closed { break }
            await handle(line)
        }
        runTask?.cancel()
        await close(.exited(0))
    }

    private func handle(_ line: Data) async {
        let message: RPCMessage
        do {
            message = try LineCodec.decode(line)
        } catch {
            // The id is unknown, so the error response carries `"id": null`.
            let reply: JSONValue = [
                "jsonrpc": "2.0", "id": nil,
                "error": ["code": .int(Int64(error.code)), "message": .string(error.message)],
            ]
            if !closed {
                var bytes = LineCodec.encodeJSON(reply)
                bytes.append(0x0A)
                await endpoint.write(bytes)
            }
            return
        }
        switch message {
        case .request(let request):
            let outcome = await dispatch(request)
            await send(.response(RPCResponse(id: request.id, outcome: outcome)))
            if request.method == RPCMethod.runStart, case .success = outcome { beginRun() }
            if request.method == RPCMethod.shutdown { await close(.exited(0)) }
        case .response(let response):
            let answer = (try? response.outcome.get())?["answer"]?.stringValue
            asks.removeValue(forKey: response.id)?.resume(returning: answer)
        case .notification:
            break
        }
    }

    private func dispatch(_ request: RPCRequest) async -> Result<JSONValue, RPCError> {
        let params = request.params ?? .object([:])
        do {
            switch request.method {
            case RPCMethod.initialize: return try initialize(params)
            case RPCMethod.runStart: return try start(params)
            case RPCMethod.runSend: return try await deliver(params)
            case RPCMethod.runStop: return try await stop(params)
            case RPCMethod.runTranscript:
                try require(script.capabilities.transcript, params)
                return try encode(TranscriptResult(events: events))
            case RPCMethod.runCost:
                try require(true, params)
                return try encode(run?.cost ?? CostResult())
            case RPCMethod.shutdown: return .success(.object([:]))
            default:
                throw RPCError(
                    code: RPCErrorCode.methodNotFound, message: "unknown method \(request.method)")
            }
        } catch let error as RPCError {
            return .failure(error)
        } catch {
            return .failure(RPCError(code: RPCErrorCode.invalidParams, message: "\(error)"))
        }
    }

    private func initialize(_ params: JSONValue) throws -> Result<JSONValue, RPCError> {
        let request = try params.decode(InitializeParams.self)
        guard request.protocolVersion == adapterProtocolVersion else {
            throw RPCError(
                code: RPCErrorCode.unsupportedProtocol,
                message: "unsupported protocol \(request.protocolVersion)")
        }
        return try encode(
            InitializeResult(adapter: script.adapter, capabilities: script.capabilities))
    }

    private func start(_ params: JSONValue) throws -> Result<JSONValue, RPCError> {
        guard session == nil else {
            throw RPCError(code: RPCErrorCode.busy, message: "busy: this process already has a run")
        }
        let request = try params.decode(RunStartParams.self)
        guard let match = script.response(for: request.input.text) else {
            throw RPCError(
                code: RPCErrorCode.harnessFailure, message: "no script response for input")
        }
        if let error = match.startError { throw error }
        session = "fake-\(request.run)"
        run = match
        return try encode(RunStartResult(session: session ?? ""))
    }

    private func deliver(_ params: JSONValue) async throws -> Result<JSONValue, RPCError> {
        guard script.capabilities.send else {
            throw RPCError(code: RPCErrorCode.capabilityNotSupported, message: "send unsupported")
        }
        let request = try params.decode(RunSendParams.self)
        try checkSession(request.session)
        if !resultSent {
            await emit(RunEvent(.message(role: request.message.role, text: request.message.text)))
        }
        return .success(.object([:]))
    }

    private func stop(_ params: JSONValue) async throws -> Result<JSONValue, RPCError> {
        let request = try params.decode(RunStopParams.self)
        try checkSession(request.session)
        if !resultSent, run?.ignoreStop != true {
            runTask?.cancel()
            for waiter in asks.values { waiter.resume(returning: nil) }
            asks = [:]
            Task { await self.finish(status: .stopped, result: nil) }
        }
        return .success(.object([:]))
    }

    private func require(_ capability: Bool, _ params: JSONValue) throws {
        guard capability else {
            throw RPCError(code: RPCErrorCode.capabilityNotSupported, message: "not supported")
        }
        try checkSession(try params.decode(SessionParams.self).session)
    }

    private func checkSession(_ id: String) throws {
        guard let session, id == session else {
            throw RPCError(code: RPCErrorCode.unknownSession, message: "unknown session \(id)")
        }
    }

    private func encode(_ value: some Encodable) throws -> Result<JSONValue, RPCError> {
        .success(try JSONValue(encoding: value))
    }

    // MARK: The run

    private func beginRun() {
        guard let run else { return }
        runTask = Task { await self.perform(run) }
    }

    private func perform(_ run: FakeScript.Response) async {
        for step in run.allSteps {
            if Task.isCancelled || closed { return }
            switch step {
            case .event(let event):
                await emit(event)
            case .sleep(let milliseconds):
                try? await Task.sleep(for: .milliseconds(milliseconds))
            case .ask(let question, let to):
                let answer = await ask(question: question, to: to)
                if Task.isCancelled { return }
                await emit(RunEvent(.message(role: "human", text: answer ?? "")))
            case .stdout(let text):
                await endpoint.write(Data((text + "\n").utf8))
            case .crash(let code):
                await close(.exited(code))
                return
            case .hang:
                while !Task.isCancelled, !closed {
                    try? await Task.sleep(for: .seconds(3600))
                }
                return
            }
        }
        if Task.isCancelled { return }
        await finish(status: run.status, result: run.result)
    }

    private func emit(_ event: RunEvent) async {
        guard let session else { return }
        events.append(event)
        let params = RunEventParams(session: session, seq: events.count, event: event)
        await notify(RPCMethod.runEvent, params)
    }

    private func ask(question: String, to: String?) async -> String? {
        guard let session else { return nil }
        let id = RPCID.string("ask-\(nextAsk)")
        nextAsk += 1
        let params = HostAskParams(session: session, question: question, to: to)
        guard let value = try? JSONValue(encoding: params) else { return nil }
        return await withCheckedContinuation { waiter in
            asks[id] = waiter
            Task {
                await self.send(
                    .request(RPCRequest(id: id, method: RPCMethod.hostAsk, params: value)))
            }
        }
    }

    private func finish(status: RunStatus, result: JSONValue?) async {
        guard !resultSent, let session else { return }
        resultSent = true
        await notify(
            RPCMethod.runResult, RunResultParams(session: session, status: status, result: result))
    }

    private func notify(_ method: String, _ params: some Encodable) async {
        guard let value = try? JSONValue(encoding: params) else { return }
        await send(.notification(RPCNotification(method: method, params: value)))
    }

    private func send(_ message: RPCMessage) async {
        guard !closed else { return }
        await endpoint.write(LineCodec.encode(message))
    }

    private func close(_ exit: AdapterExit) async {
        guard !closed else { return }
        closed = true
        runTask?.cancel()
        for waiter in asks.values { waiter.resume(returning: nil) }
        asks = [:]
        await endpoint.close(exit)
    }
}

extension RPCResponse {
    init(id: RPCID, outcome: Result<JSONValue, RPCError>) {
        switch outcome {
        case .success(let value): self.init(id: id, result: value)
        case .failure(let error): self.init(id: id, error: error)
        }
    }
}
