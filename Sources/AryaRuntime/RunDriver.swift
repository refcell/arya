import AryaAdapters
import AryaCore
import Foundation

/// Drives one run: handshake, streaming, result, dispositions, and the closing event.
final class RunDriver: @unchecked Sendable {
    // Confined to `drive()`, which runs on one task; no state is shared across tasks.
    private let loop: RunLoop
    private let request: RunRequest
    private let charter: Charter
    private let run: RunID
    private let instructions: String
    private var phase = RunPhase.started
    private var session: String?
    private var leak = false

    init(loop: RunLoop, request: RunRequest, charter: Charter, run: RunID, instructions: String) {
        self.loop = loop
        self.request = request
        self.charter = charter
        self.run = run
        self.instructions = instructions
    }

    func drive() async throws -> RunOutcome {
        let adapter: any Adapter
        do {
            adapter = try await loop.adapters.makeAdapter(for: charter, run: run)
        } catch {
            return try await fail(.adapterExited, detail: "launch: \(error)", cost: 0)
        }
        var updates = adapter.updates.makeAsyncIterator()
        if let failure = await handshake(adapter) {
            try? await adapter.shutdown()
            try await drain(&updates)
            return try await fail(failure.0, detail: failure.1, cost: 0)
        }
        try transition(.adapterStarted)
        return try await stream(adapter, &updates)
    }

    // MARK: Handshake

    private func handshake(_ adapter: any Adapter) async -> (RunFailureReason, String)? {
        do {
            _ = try await adapter.initialize(
                InitializeParams(client: PeerInfo(name: "arya", version: "0.1.0")))
            let started = try await adapter.start(try startParams())
            session = started.session
            return nil
        } catch let error as AdapterError {
            if case .exited = error { return (.adapterExited, "\(error)") }
            return (.adapterFailed, "\(error)")
        } catch {
            return (.adapterFailed, "\(error)")
        }
    }

    private func startParams() throws -> RunStartParams {
        let limits = charter.limits
        return RunStartParams(
            run: run.rawValue, instructions: instructions, input: request.input,
            effort: charter.effort.rawValue, workdir: try loop.workdir(run), tools: [],
            limits: RunLimits(
                maxTurns: limits.maxTurns, timeoutSeconds: limits.timeoutSeconds,
                maxCostMicros: limits.maxCostMicros),
            resultSchema: RunResultSchema.value)
    }

    // MARK: Streaming

    /// Records the remaining wire lines until the adapter exits.
    private func drain(_ updates: inout AsyncStream<AdapterUpdate>.Iterator) async throws {
        while let update = await updates.next() {
            if case .wire(let record) = update { try await recordWire(record) }
            if case .exited = update { return }
        }
    }

    private func stream(
        _ adapter: any Adapter, _ updates: inout AsyncStream<AdapterUpdate>.Iterator
    ) async throws -> RunOutcome {
        while let update = await updates.next() {
            switch update {
            case .wire(let record):
                try await recordWire(record)
            case .event(let params):
                try transition(.adapterEvent)
                noteToolCall(params.event)
            case .ask(let id, _):
                // Answered by the next backlog item (`host/ask` through the approval queue).
                try? await adapter.answer(id, HostAskResult(answer: nil))
            case .result(let params):
                return try await finish(adapter, params, &updates)
            case .protocolError:
                continue
            case .timedOut:
                return try await abandon(adapter, &updates, .timeout, "no message in time")
            case .exited(let exit):
                return try await fail(.adapterExited, detail: "\(exit)", cost: 0)
            }
        }
        return try await fail(.adapterExited, detail: "update stream ended", cost: 0)
    }

    private func noteToolCall(_ event: RunEvent) {
        guard case .rehearsal(let context) = request.mode,
            case .toolCall(_, let tool, let input) = event.body
        else { return }
        let answered = context.toolResults.contains { $0.tool == tool && $0.input == input }
        if !answered { leak = true }
    }

    private func recordWire(_ record: WireRecord) async throws {
        let message: JSONValue =
            (try? CanonicalJSON.decode(JSONValue.self, from: record.line))
            ?? ["raw": .string(String(decoding: record.line, as: UTF8.self))]
        let payload: JSONValue = [
            "direction": .string(record.direction.rawValue), "message": message,
        ]
        try await append(RunEventType.adapterEvent, .adapter(run), payload)
    }

    // MARK: Ending

    private func finish(
        _ adapter: any Adapter, _ params: RunResultParams,
        _ updates: inout AsyncStream<AdapterUpdate>.Iterator
    ) async throws -> RunOutcome {
        let cost = await closeAdapter(adapter, &updates)
        guard let result = try? params.decodedResult() else {
            return try await fail(.invalidResult, detail: "result does not decode", cost: cost)
        }
        if params.status == .failed {
            return try await fail(.adapterFailed, detail: result.summary, cost: cost)
        }
        let end: RunEndStatus = params.status == .stopped ? .stopped : .completed
        try transition(.resultReceived(end))
        for decision in result.decisions {
            try await append(
                RunEventType.decision, .steward(charter.id), try Payload.encode(decision))
        }
        let actions = result.actions.map(ProposedAction.init)
        let disposals = try await dispose(actions)
        try transition(.dispositionsRecorded)
        let payload = RunEndPayload(
            status: end.rawValue, summary: result.summary, costMicros: cost,
            decisions: result.decisions.count, actions: actions.count, leak: leak)
        try await append(RunEventType.finished, .system, try Payload.encode(payload))
        return RunOutcome(run: run, phase: phase, result: result, disposals: disposals, leak: leak)
    }

    private func dispose(_ actions: [ProposedAction]) async throws -> [ActionDisposal] {
        switch request.mode {
        case .live:
            return try await loop.dispatcher.dispose(actions, charter: charter, run: run)
        case .rehearsal:
            return try await loop.dispatcher.recordOnly(actions, charter: charter, run: run)
        }
    }

    /// Asks for the cost, shuts the adapter down, and records the remaining wire lines.
    private func closeAdapter(
        _ adapter: any Adapter, _ updates: inout AsyncStream<AdapterUpdate>.Iterator
    ) async -> Int64 {
        var cost: Int64 = 0
        if let session, let answer = try? await adapter.cost(SessionParams(session: session)) {
            cost = answer.costMicros
        }
        try? await adapter.shutdown()
        try? await drain(&updates)
        return cost
    }

    private func abandon(
        _ adapter: any Adapter, _ updates: inout AsyncStream<AdapterUpdate>.Iterator,
        _ reason: RunFailureReason, _ detail: String
    ) async throws -> RunOutcome {
        try? await adapter.shutdown()
        try? await drain(&updates)
        return try await fail(reason, detail: detail, cost: 0)
    }

    private func fail(_ reason: RunFailureReason, detail: String, cost: Int64) async throws
        -> RunOutcome
    {
        try transition(.fail(reason))
        let payload = RunEndPayload(
            reason: reason.rawValue, detail: detail, costMicros: cost, decisions: 0, actions: 0,
            leak: leak)
        try await append(RunEventType.failed, .system, try Payload.encode(payload))
        return RunOutcome(run: run, phase: phase, result: nil, disposals: [], leak: leak)
    }

    private func transition(_ input: RunPhaseInput) throws {
        phase = try phase.applying(input)
    }

    private func append(_ type: String, _ actor: RuntimeActor, _ payload: JSONValue) async throws {
        _ = try await loop.sink.append(
            RuntimeEventDraft(
                type: type, steward: charter.id, run: run, actor: actor, payload: payload))
    }
}

extension ProposedAction {
    /// The runtime's record of an action from `run/result`.
    public init(_ action: RunResult.Action) {
        self.init(
            id: action.id, kind: action.kind, binding: action.binding, target: action.target,
            params: action.params, rationale: action.rationale)
    }
}

/// The JSON Schema of `run/result.result` sent in `run/start.resultSchema`.
public enum RunResultSchema {
    /// The schema value.
    public static let value: JSONValue = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "decisions": list(["id", "choice"]),
            "actions": list(["id", "kind"]),
            "delegations": list(["id", "title", "input"]),
            "memories": list(["text"]),
            "routines": list(["name", "language", "content"]),
            "measurements": list(["metric", "value"]),
        ],
    ]

    private static func list(_ required: [String]) -> JSONValue {
        [
            "type": "array",
            "items": ["type": "object", "required": .array(required.map { .string($0) })],
        ]
    }
}
