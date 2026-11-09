import AryaAdapters
import AryaCore
import AryaLedger
import Foundation

/// Drives one run: handshake, streaming, result, dispositions, and the closing event.
final class RunDriver: @unchecked Sendable {
    // Confined to `drive()`, which runs on one task; no state is shared across tasks.
    private let loop: RunEngine
    private let request: RunRequest
    private let charter: Charter
    private let run: RunID
    private let instructions: String
    private var phase = RunPhase.started
    private var session: String?
    private var leak = false

    init(loop: RunEngine, request: RunRequest, charter: Charter, run: RunID, instructions: String) {
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
            return try await fail(.adapterExited, detail: "launch: \(error)", cost: nil)
        }
        var updates = adapter.updates.makeAsyncIterator()
        if let failure = await handshake(adapter) {
            try? await adapter.shutdown()
            try await drain(&updates)
            return try await fail(failure.0, detail: failure.1, cost: nil)
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
            case .ask(let id, let params):
                let answer = try await ask(params)
                try? await adapter.answer(id, HostAskResult(answer: answer))
            case .result(let params):
                return try await finish(adapter, params, &updates)
            case .protocolError:
                continue
            case .timedOut:
                return try await abandon(adapter, &updates, .timeout, "no message in time")
            case .exited(let exit):
                return try await fail(.adapterExited, detail: "\(exit)", cost: nil)
            }
        }
        return try await fail(.adapterExited, detail: "update stream ended", cost: nil)
    }

    /// Puts a `host/ask` question in the approval queue and waits until a person answers it
    /// or the run's timeout passes (then it expires and the answer is `null`). Rehearsal never
    /// asks anyone: an unrecorded question answers `null` (PROTOCOL.md).
    private func ask(_ params: HostAskParams) async throws -> String? {
        guard request.mode == .live else { return nil }
        let timeout = Int64(charter.limits.timeoutSeconds) * 1000
        let record = try await loop.approvals.request(
            .question(params.question), steward: charter.id, run: run, to: params.to ?? "local",
            expiresAt: loop.ambient.now().adding(milliseconds: timeout))
        while true {
            let current = try await loop.approvals.book().records[record.id]
            switch current?.status {
            case .granted?: return current?.note
            case .denied?, .expired?, nil: return nil
            case .pending?: break
            }
            if try await !loop.approvals.expireDue(now: loop.ambient.now()).isEmpty {
                return nil
            }
            try await Task.sleep(for: loop.questionPoll)
        }
    }

    private func noteToolCall(_ event: RunEvent) {
        guard case .rehearsal(let context) = request.mode,
            case .toolCall(_, let tool, let input) = event.body
        else { return }
        let answered = context.toolResults.contains { $0.tool == tool && $0.input == input }
        if !answered { leak = true }
    }

    private func recordWire(_ record: WireRecord) async throws {
        let direction: RunAdapterEvent.Direction = record.direction == .sent ? .sent : .received
        let payload =
            if let message = try? CanonicalJSON.decode(JSONValue.self, from: record.line) {
                RunAdapterEvent(direction: direction, message: message)
            } else {
                RunAdapterEvent(
                    direction: direction, raw: String(decoding: record.line, as: UTF8.self))
            }
        try await append(
            RunEventType.adapterEvent, .adapter(charter.adapter), try Payload.encode(payload))
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
            let recorded = RecordedDecision(
                id: decision.id, choice: decision.choice, rationale: decision.rationale)
            try await append(
                RunEventType.decision, .steward(charter.id),
                try Payload.encode(RunDecision(decision: recorded)))
        }
        let actions = result.actions.map(ProposedAction.init)
        let disposals = try await dispose(actions)
        try transition(.dispositionsRecorded)
        let counts = RunCounts(
            decisions: result.decisions.count, actions: actions.count,
            delegations: result.delegations.count, memories: result.memories.count,
            routines: result.routines.count, measurements: result.measurements.count)
        let payload = RunFinished(
            status: end == .stopped ? .stopped : .completed, summary: result.summary,
            cost: cost ?? RunCost(), counts: counts)
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
    ) async -> RunCost? {
        var cost: RunCost?
        if let session, let answer = try? await adapter.cost(SessionParams(session: session)) {
            cost = RunCost(
                inputTokens: answer.inputTokens, outputTokens: answer.outputTokens,
                costMicros: answer.costMicros)
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
        return try await fail(reason, detail: detail, cost: nil)
    }

    private func fail(_ reason: RunFailureReason, detail: String, cost: RunCost?) async throws
        -> RunOutcome
    {
        try transition(.fail(reason))
        let payload = RunFailed(reason: reason.rawValue, detail: detail, cost: cost)
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
