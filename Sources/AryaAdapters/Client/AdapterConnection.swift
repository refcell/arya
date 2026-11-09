import AryaCore
import Foundation

/// Time limits an ``AdapterConnection`` enforces.
public struct ConnectionTimeouts: Sendable, Hashable {
    /// How long a request may wait for its response.
    public var request: Duration
    /// Idle time before `run/stop` with reason `timeout`. `nil` uses the run's
    /// `limits.timeoutSeconds`; with neither, there is no idle timeout.
    public var idle: Duration?
    /// How long the adapter has after `run/stop` to send `run/result` before it is terminated.
    public var stopGrace: Duration
    /// How long after SIGTERM before SIGKILL.
    public var killGrace: Duration
    /// How long the adapter has to exit after `shutdown` before it is terminated.
    public var exitGrace: Duration

    public init(
        request: Duration = .seconds(30), idle: Duration? = nil, stopGrace: Duration = .seconds(10),
        killGrace: Duration = .seconds(5), exitGrace: Duration = .seconds(5)
    ) {
        self.request = request
        self.idle = idle
        self.stopGrace = stopGrace
        self.killGrace = killGrace
        self.exitGrace = exitGrace
    }

    /// The protocol's defaults: 30 s requests, 10 s stop grace, 5 s kill and exit grace.
    public static let standard = ConnectionTimeouts()
}

/// An ``Adapter`` over any ``AdapterTransport``: matches responses to requests by id, turns
/// notifications and adapter requests into ``AdapterUpdate``s, records every line, and
/// supervises the run (idle timeout, stop grace, termination).
public actor AdapterConnection: Adapter {
    public nonisolated let updates: AsyncStream<AdapterUpdate>
    private let continuation: AsyncStream<AdapterUpdate>.Continuation
    private let transport: any AdapterTransport
    private let timeouts: ConnectionTimeouts

    private enum Slot {
        case waiting(CheckedContinuation<Result<JSONValue, AdapterError>, Never>?)
        case done(Result<JSONValue, AdapterError>)
    }

    private var nextID: Int64 = 1
    private var slots: [RPCID: Slot] = [:]
    private var exit: AdapterExit?
    private var exitWaiters: [Int: CheckedContinuation<AdapterExit?, Never>] = [:]
    private var nextWaiter = 0
    private var session: String?
    private var resultSeen = false
    private var activity = 0
    /// `host/ask` requests the host has not answered; the idle timer pauses while any is open.
    private var openAsks: Set<RPCID> = []
    private var supervisor: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    public init(transport: any AdapterTransport, timeouts: ConnectionTimeouts = .standard) {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.transport = transport
        self.timeouts = timeouts
    }

    /// Starts reading the transport. Called by every request; safe to call more than once.
    public func open() {
        guard reader == nil else { return }
        let input = transport.input
        reader = Task { [weak self] in
            for await item in input {
                await self?.handle(item)
            }
        }
    }

    // MARK: Requests

    public func initialize(_ params: InitializeParams) async throws(AdapterError)
        -> InitializeResult
    {
        try await call(RPCMethod.initialize, params, as: InitializeResult.self)
    }

    public func start(_ params: RunStartParams) async throws(AdapterError) -> RunStartResult {
        let result = try await call(RPCMethod.runStart, params, as: RunStartResult.self)
        session = result.session
        let limit = params.limits.timeoutSeconds.map { Duration.seconds($0) }
        if let idle = timeouts.idle ?? limit { superviseIdle(idle) }
        return result
    }

    public func send(_ params: RunSendParams) async throws(AdapterError) {
        _ = try await call(RPCMethod.runSend, params, as: EmptyObject.self)
    }

    /// Sends `run/stop`. If no `run/result` follows within the stop grace, the adapter is
    /// terminated.
    public func stop(_ params: RunStopParams) async throws(AdapterError) {
        superviseStop()
        _ = try await call(RPCMethod.runStop, params, as: EmptyObject.self)
    }

    public func transcript(_ params: SessionParams) async throws(AdapterError)
        -> TranscriptResult
    {
        try await call(RPCMethod.runTranscript, params, as: TranscriptResult.self)
    }

    public func cost(_ params: SessionParams) async throws(AdapterError) -> CostResult {
        try await call(RPCMethod.runCost, params, as: CostResult.self)
    }

    public func shutdown() async throws(AdapterError) {
        defer { supervisor?.cancel() }
        if exit != nil { return }
        let outcome: Result<EmptyObject, AdapterError>
        do {
            outcome = .success(
                try await call(RPCMethod.shutdown, EmptyObject(), as: EmptyObject.self))
        } catch {
            outcome = .failure(error)
        }
        await transport.closeInput()
        if await waitForExit(within: timeouts.exitGrace) == nil {
            await transport.terminate(grace: timeouts.killGrace)
            _ = await waitForExit(within: timeouts.killGrace + .seconds(1))
        }
        if case .failure(let error) = outcome, case .exited = error {
            return
        }
        _ = try outcome.get()
    }

    public func answer(_ id: RPCID, _ result: HostAskResult) async throws(AdapterError) {
        let value: JSONValue
        do {
            value = try JSONValue(encoding: result)
        } catch {
            throw .invalidResponse(method: RPCMethod.hostAsk, detail: "\(error)")
        }
        openAsks.remove(id)
        activity += 1
        try await write(.response(RPCResponse(id: id, result: value)))
    }

    /// Sends any request and returns its raw result. Used by the conformance suite and for
    /// methods this module does not type.
    public func request(_ method: String, params: JSONValue? = nil) async throws(AdapterError)
        -> JSONValue
    {
        try await call(method, params ?? .object([:]), as: JSONValue.self)
    }

    /// Waits until the adapter is gone and returns how it ended.
    public func waitForExit() async -> AdapterExit {
        open()
        while true {
            if let exit = await waitForExit(within: nil) { return exit }
        }
    }

    // MARK: Plumbing

    private func call<R: Decodable>(
        _ method: String, _ params: some Encodable, as type: R.Type
    ) async throws(AdapterError) -> R {
        open()
        if let exit { throw .exited(exit) }
        let paramsValue: JSONValue
        do {
            paramsValue = try JSONValue(encoding: params)
        } catch {
            throw .invalidResponse(method: method, detail: "params do not encode: \(error)")
        }
        let id = RPCID.int(nextID)
        nextID += 1
        slots[id] = .waiting(nil)
        let timeout = timeouts.request
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.resolve(id, .failure(.requestTimedOut(method: method)))
        }
        defer { timer.cancel() }
        do {
            try await write(.request(RPCRequest(id: id, method: method, params: paramsValue)))
        } catch {
            slots[id] = nil
            throw error
        }
        let value = try await awaitSlot(id).get()
        do {
            return try value.decode(type)
        } catch {
            throw .invalidResponse(method: method, detail: "\(error)")
        }
    }

    private func awaitSlot(_ id: RPCID) async -> Result<JSONValue, AdapterError> {
        if case .done(let result)? = slots[id] {
            slots[id] = nil
            return result
        }
        return await withCheckedContinuation { slots[id] = .waiting($0) }
    }

    private func resolve(_ id: RPCID, _ result: Result<JSONValue, AdapterError>) {
        switch slots[id] {
        case .waiting(let waiter?)?:
            slots[id] = nil
            waiter.resume(returning: result)
        case .waiting(nil)?:
            slots[id] = .done(result)
        case .done?, nil:
            break
        }
    }

    private func write(_ message: RPCMessage) async throws(AdapterError) {
        if let exit { throw .exited(exit) }
        let line = LineCodec.encode(message)
        continuation.yield(
            .wire(WireRecord(direction: .sent, line: line.dropLast(), message: message)))
        do {
            try await transport.write(line)
        } catch {
            throw .writeFailed("\(error)")
        }
    }

    private func handle(_ input: TransportInput) async {
        switch input {
        case .line(let line):
            activity += 1
            await handleLine(line)
        case .ended(let status):
            finish(status)
        }
    }

    private func handleLine(_ line: Data) async {
        let (message, meaning) = Interpretation.of(line: line)
        continuation.yield(.wire(WireRecord(direction: .received, line: line, message: message)))
        if meaning.isResult {
            resultSeen = true
            supervisor?.cancel()
        }
        for update in meaning.updates {
            if case .ask(let id, _) = update { openAsks.insert(id) }
            continuation.yield(update)
        }
        if let response = meaning.response {
            resolve(response.id, response.outcome.mapError { .rpc($0) })
        }
        if let reply = meaning.reply { try? await write(.response(reply)) }
    }

    private func finish(_ status: AdapterExit) {
        guard exit == nil else { return }
        exit = status
        supervisor?.cancel()
        for (id, _) in slots { resolve(id, .failure(.exited(status))) }
        continuation.yield(.exited(status))
        continuation.finish()
        let waiters = exitWaiters
        exitWaiters = [:]
        for waiter in waiters.values { waiter.resume(returning: status) }
    }

    /// Waits for the exit, or returns `nil` once `limit` passes.
    private func waitForExit(within limit: Duration?) async -> AdapterExit? {
        if let exit { return exit }
        let key = nextWaiter
        nextWaiter += 1
        var timer: Task<Void, Never>?
        if let limit {
            timer = Task { [weak self] in
                try? await Task.sleep(for: limit)
                await self?.expireWaiter(key)
            }
        }
        defer { timer?.cancel() }
        return await withCheckedContinuation { exitWaiters[key] = $0 }
    }

    private func expireWaiter(_ key: Int) {
        exitWaiters.removeValue(forKey: key)?.resume(returning: nil)
    }

    // MARK: Supervision

    private func superviseIdle(_ idle: Duration) {
        supervisor?.cancel()
        supervisor = Task { [weak self] in
            var seen = await self?.activity ?? 0
            while !Task.isCancelled {
                try? await Task.sleep(for: idle)
                guard !Task.isCancelled, let self else { return }
                let now = await self.activity
                if now == seen, await self.openAsks.isEmpty {
                    await self.idleExpired()
                    return
                }
                seen = now
            }
        }
    }

    private func idleExpired() async {
        guard !resultSeen, exit == nil, let session else { return }
        continuation.yield(.timedOut)
        superviseStop()
        let params = RunStopParams(session: session, reason: .timeout)
        Task { [weak self] in try? await self?.call(RPCMethod.runStop, params, as: EmptyObject.self)
        }
    }

    private func superviseStop() {
        supervisor?.cancel()
        let grace = timeouts.stopGrace
        supervisor = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.stopGraceExpired()
        }
    }

    private func stopGraceExpired() async {
        guard !resultSeen, exit == nil else { return }
        await transport.terminate(grace: timeouts.killGrace)
    }
}
