import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import Foundation

/// Drives one run: handshake, streaming, result, dispositions, and the closing event.
final class RunDriver: @unchecked Sendable {
    // Confined to `drive()`, which runs on one task; no state is shared across tasks.
    private let loop: RunEngine
    private let request: RunRequest
    private let charter: Charter
    private let run: RunID
    private let instructions: String
    private let routines: [String: String]
    private var phase = RunPhase.started
    private var session: String?
    private var leak = false
    private var turns = 0
    private let overdue = Flag()

    init(
        loop: RunEngine, request: RunRequest, charter: Charter, run: RunID, instructions: String,
        routines: [String: String]
    ) {
        self.routines = routines
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
        let deadline = startDeadline(adapter)
        defer { deadline.cancel() }
        return try await stream(adapter, &updates)
    }

    // MARK: Budgets

    /// After `limits.timeoutSeconds` asks the adapter to stop; the run then fails `timeout`.
    private func startDeadline(_ adapter: any Adapter) -> Task<Void, Never> {
        let wait = loop.secondsUnit * charter.limits.timeoutSeconds
        let overdue = overdue
        let session = session
        return Task {
            guard (try? await Task.sleep(for: wait)) != nil else { return }
            overdue.set()
            if let session {
                try? await adapter.stop(RunStopParams(session: session, reason: .timeout))
            }
        }
    }

    /// Counts assistant messages as turns and, after each turn, checks `run/cost`.
    private func budgetBreach(_ adapter: any Adapter, _ event: RunEvent) async -> String? {
        guard case .message(let role, _) = event.body, role == "assistant" else { return nil }
        turns += 1
        let limits = charter.limits
        if turns > limits.maxTurns { return "max_turns: \(turns) > \(limits.maxTurns)" }
        if let session, let cost = try? await adapter.cost(SessionParams(session: session)),
            cost.costMicros > limits.maxCostMicros
        {
            return "max_cost_micros: \(cost.costMicros) > \(limits.maxCostMicros)"
        }
        return nil
    }

    /// Sends `run/stop`, waits for the adapter's last word, and fails the run.
    private func stopAndFail(
        _ adapter: any Adapter, _ updates: inout AsyncStream<AdapterUpdate>.Iterator,
        _ reason: RunFailureReason, _ stop: StopReason, _ detail: String
    ) async throws -> RunOutcome {
        if let session { try? await adapter.stop(RunStopParams(session: session, reason: stop)) }
        loop: while let update = await updates.next() {
            switch update {
            case .wire(let record): try await recordWire(record)
            case .result, .exited, .timedOut: break loop
            case .event, .ask, .protocolError: continue
            }
        }
        let cost = await closeAdapter(adapter, &updates)
        return try await fail(reason, detail: detail, cost: cost)
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
        let workdir = try loop.workdir(run)
        return RunStartParams(
            run: run.rawValue, instructions: instructions, input: request.input,
            effort: charter.effort.rawValue, workdir: workdir, tools: try toolServers(workdir),
            limits: RunLimits(
                maxTurns: limits.maxTurns, timeoutSeconds: limits.timeoutSeconds,
                maxCostMicros: limits.maxCostMicros),
            resultSchema: RunResultSchema.value)
    }

    /// Binding proxies for the harness. In rehearsal the case's recorded tool results are
    /// written to `<workdir>/tool-results.json` and the proxies answer from them.
    private func toolServers(_ workdir: String) throws -> [ToolServer] {
        guard let proxy = loop.proxy else { return [] }
        var recorded: String?
        if case .rehearsal(let context) = request.mode {
            let file = URL(fileURLWithPath: workdir).appendingPathComponent("tool-results.json")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try CanonicalJSON.encode(context.toolResults).write(to: file)
            recorded = file.path
        }
        return proxy.servers(charter: charter, run: run, recorded: recorded)
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
                if let breach = await budgetBreach(adapter, params.event) {
                    return try await stopAndFail(adapter, &updates, .budget, .budget, breach)
                }
            case .ask(let id, let params):
                let answer = try await ask(params)
                try? await adapter.answer(id, HostAskResult(answer: answer))
            case .result(let params):
                if overdue.isSet {
                    let cost = await closeAdapter(adapter, &updates)
                    return try await fail(.timeout, detail: overdueDetail, cost: cost)
                }
                return try await finish(adapter, params, &updates)
            case .protocolError:
                continue
            case .timedOut:
                return try await abandon(adapter, &updates, .timeout, "no message in time")
            case .exited(let exit):
                if overdue.isSet {
                    return try await fail(.timeout, detail: overdueDetail, cost: nil)
                }
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

    /// Records `plan.updated` when the result carries a plan that differs from the current one.
    private func recordPlan(_ result: RunResult) async throws {
        guard let plan = PlanBook.plan(in: result) else { return }
        let current = try PlanBook(try await loop.sink.events(from: 1)).plans[charter.id]
        guard PlanBook.differs(plan, current) else { return }
        let reason = result.summary.isEmpty ? nil : result.summary
        try await append(
            PlanEventType.updated, .steward(charter.id),
            try Payload.encode(PlanUpdated(items: plan, reason: reason)))
    }

    /// Records `memory.added` for each new, valid note a live run proposes (memory's intake
    /// drops duplicates of live notes and invalid notes).
    private func recordMemories(_ memories: [RunResult.Memory]) async throws {
        guard !memories.isEmpty else { return }
        let view = try MemoryView(try await loop.sink.events(from: 1))
        let intake = try MemoryIntake.notes(
            memories.map { ProposedNote(text: $0.text, tags: $0.tags) }, steward: charter.id,
            run: run, live: view.memory, ambient: loop.ambient)
        for draft in intake.drafts {
            _ = try await loop.sink.append(RuntimeEventDraft(draft))
        }
    }

    private var overdueDetail: String {
        "ran past timeoutSeconds: \(charter.limits.timeoutSeconds)"
    }

    private func noteToolCall(_ event: RunEvent) {
        guard case .rehearsal(let context) = request.mode,
            case .toolCall(_, let tool, let input) = event.body
        else { return }
        let answered = context.toolResults.contains { $0.tool == tool && $0.input == input }
        if !answered { leak = true }
    }

    private func recordWire(_ record: WireRecord) async throws {
        try await append(RunEventType.adapterEvent, .adapter(charter.adapter), record.ledgerPayload)
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
        if case .live = request.mode {
            if !request.isCrewChild { try await recordPlan(result) }
            try await recordMemories(result.memories)
            for measurement in result.measurements {
                try await append(
                    MetricEventType.recorded, .steward(charter.id),
                    try Payload.encode(
                        MetricRecorded(metric: measurement.metric, value: measurement.value)))
            }
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
        case .live where request.isCrewChild:
            return try await loop.dispatcher.recordOnly(
                actions, charter: charter, run: run, routines: routines)
        case .live:
            return try await loop.dispatcher.dispose(
                actions, charter: charter, run: run, routines: routines)
        case .rehearsal:
            return try await loop.dispatcher.recordOnly(
                actions, charter: charter, run: run, routines: routines)
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
            "plan": list(
                ["id", "text", "status"],
                properties: [
                    "status": [
                        "enum": ["pending", "in_progress", "done", "skipped", "blocked"]
                    ]
                ],
                description: "The run's plan at the end: each step and how far it got."),
            "decisions": list(
                ["id", "choice"], properties: ["why": why],
                description: "Choices made; `why` is one line a person reads."),
            "actions": list(
                ["id", "kind"],
                properties: ["risk": ["enum": ["low", "medium", "high"]], "why": why],
                description: "Proposed actions; `risk` is a hint and `why` one line a person reads."
            ),
            "delegations": list(["id", "title", "input"]),
            "memories": list(["text"]),
            "routines": list(["name", "language", "content"]),
            "measurements": list(["metric", "value"]),
            "plan": list(["id", "text", "status"]),
        ],
    ]

    private static let why: JSONValue = [
        "type": "string", "description": "One short line: the human reason for this item.",
    ]

    private static func list(
        _ required: [String], properties: [String: JSONValue] = [:], description: String? = nil
    ) -> JSONValue {
        var items: [String: JSONValue] = [
            "type": "object", "required": .array(required.map { .string($0) }),
        ]
        if !properties.isEmpty { items["properties"] = .object(properties) }
        var list: [String: JSONValue] = ["type": "array", "items": .object(items)]
        if let description { list["description"] = .string(description) }
        return .object(list)
    }
}

/// A one-way flag set from the deadline task and read by the driver.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}
