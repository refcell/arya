import AryaCore
import AryaLedger

// Agents propose, arya disposes (decision 0005). The dispatcher records every proposed action,
// classifies it with the charter's policy, and then executes it (`auto`), queues it for a
// person (`ask`), or rejects it (`deny`). Executor output lands on `action.executed` or
// `action.failed`, which replay serves back as recorded inputs.

/// Ledger event types for actions.
public enum ActionEventType {
    /// A run proposed an action; carries its disposition.
    public static let proposed = EventType.actionProposed.rawValue
    /// arya carried the action out.
    public static let executed = EventType.actionExecuted.rawValue
    /// Carrying the action out failed.
    public static let failed = EventType.actionFailed.rawValue
    /// Policy or a person refused the action.
    public static let rejected = EventType.actionRejected.rawValue
}

/// One action to carry out.
public struct ExecutionRequest: Sendable, Hashable {
    /// Steward that proposed it.
    public var steward: StewardID
    /// Run that proposed it.
    public var run: RunID
    /// The action.
    public var action: ProposedAction
    /// The charter binding that carries it out; `nil` for `routine`.
    public var binding: CharterBinding?
    /// The approval that released it, for `ask` actions.
    public var approval: ApprovalID?
    /// For a person binding with `via`: the MCP binding that relays to them.
    public var relay: CharterBinding?

    /// Creates a request.
    public init(
        steward: StewardID, run: RunID, action: ProposedAction, binding: CharterBinding?,
        approval: ApprovalID? = nil, relay: CharterBinding? = nil
    ) {
        self.relay = relay
        self.steward = steward
        self.run = run
        self.action = action
        self.binding = binding
        self.approval = approval
    }
}

/// What an executor reports.
public enum ExecutionOutcome: Sendable, Hashable {
    /// Done; `output` is what the system answered.
    case succeeded(output: JSONValue)
    /// Not done; `error` says why, `output` holds anything the system answered.
    case failed(error: String, output: JSONValue?)
}

/// Carries out actions against bindings and routines. Implementations never throw: every
/// failure is an outcome so it can be recorded.
public protocol ActionExecutor: Sendable {
    /// Carries out one action.
    func execute(_ request: ExecutionRequest) async -> ExecutionOutcome
}

/// An executor for tests and rehearsal-like dry runs: it records each request and answers from
/// a table keyed by action kind, defaulting to success with `{"ok": true}`.
public actor RecordingExecutor: ActionExecutor {
    /// Requests in the order they arrived.
    public private(set) var requests: [ExecutionRequest] = []
    private let outcomes: [String: ExecutionOutcome]

    /// Creates an executor that answers `outcomes[kind]` for each action kind.
    public init(outcomes: [String: ExecutionOutcome] = [:]) {
        self.outcomes = outcomes
    }

    public func execute(_ request: ExecutionRequest) async -> ExecutionOutcome {
        requests.append(request)
        return outcomes[request.action.kind] ?? .succeeded(output: ["ok": true])
    }
}

/// The disposition of one proposed action, as the dispatcher recorded it.
public struct ActionDisposal: Sendable, Hashable {
    /// The action.
    public var action: ProposedAction
    /// Policy's verdict.
    public var verdict: PolicyVerdict
    /// The approval it waits on, for `ask`.
    public var approval: ApprovalID?
    /// The executor's outcome, for `auto`.
    public var outcome: ExecutionOutcome?
}

/// Records, classifies, and carries out proposed actions.
public struct ActionDispatcher: Sendable {
    private let sink: any EventSink
    private let approvals: ApprovalQueue
    private let executor: any ActionExecutor

    /// Creates a dispatcher.
    public init(sink: any EventSink, approvals: ApprovalQueue, executor: any ActionExecutor) {
        self.sink = sink
        self.approvals = approvals
        self.executor = executor
    }

    /// Disposes each action of a run in order: `action.proposed`, then execution,
    /// `approval.requested`, or `action.rejected`.
    /// `routines` are the live routine versions by name that the run started with.
    public func dispose(
        _ actions: [ProposedAction], charter: Charter, run: RunID,
        routines: [String: String] = [:]
    ) async throws -> [ActionDisposal] {
        let policy = ActionPolicy(charter: charter)
        var disposals: [ActionDisposal] = []
        for action in actions {
            let verdict = policy.classify(action.policyAction(routines: routines))
            try await append(
                ActionEventType.proposed, charter.id, run, .steward(charter.id),
                ActionProposed(
                    action: action, disposition: verdict.disposition, reason: verdict.reason,
                    risk: verdict.risk, autonomy: verdict.autonomy))
            var disposal = ActionDisposal(action: action, verdict: verdict)
            switch verdict.disposition {
            case .auto:
                let request = ExecutionRequest(
                    steward: charter.id, run: run, action: action,
                    binding: action.binding.flatMap(charter.binding),
                    relay: Self.relay(action, charter))
                disposal.outcome = try await execute(request)
            case .ask:
                disposal.approval =
                    try await approvals.request(.action(action), steward: charter.id, run: run).id
            case .deny:
                try await reject(action.id, charter.id, run, reason: verdict.reason)
            }
            disposals.append(disposal)
        }
        return disposals
    }

    /// Records `action.proposed` with its disposition for each action and nothing else: no
    /// execution, no approval, no rejection. Used by rehearsal (decision 0015).
    /// `routines` are the live routine versions by name that the run started with.
    public func recordOnly(
        _ actions: [ProposedAction], charter: Charter, run: RunID,
        routines: [String: String] = [:]
    ) async throws -> [ActionDisposal] {
        let policy = ActionPolicy(charter: charter)
        var disposals: [ActionDisposal] = []
        for action in actions {
            let verdict = policy.classify(action.policyAction(routines: routines))
            try await append(
                ActionEventType.proposed, charter.id, run, .steward(charter.id),
                ActionProposed(
                    action: action, disposition: verdict.disposition, reason: verdict.reason,
                    risk: verdict.risk, autonomy: verdict.autonomy))
            disposals.append(ActionDisposal(action: action, verdict: verdict))
        }
        return disposals
    }

    /// Carries out the action of a granted approval, using the steward's live charter.
    public func executeGranted(_ record: ApprovalRecord, charter: Charter) async throws
        -> ExecutionOutcome
    {
        guard case .action(let action) = record.subject, record.status == .granted else {
            throw ApprovalError.alreadyDecided(record.id, record.status)
        }
        return try await execute(
            ExecutionRequest(
                steward: record.steward, run: record.run, action: action,
                binding: action.binding.flatMap(charter.binding), approval: record.id,
                relay: Self.relay(action, charter)))
    }

    /// The MCP binding a person binding's `via` names, when it is one.
    static func relay(_ action: ProposedAction, _ charter: Charter) -> CharterBinding? {
        guard let person = action.binding.flatMap(charter.binding), person.kind == .person,
            let via = person.via, let relay = charter.binding(via), relay.kind == .mcp
        else { return nil }
        return relay
    }

    /// Records `action.rejected` for the action of a denied or expired approval.
    public func rejectDecided(_ record: ApprovalRecord) async throws {
        guard case .action(let action) = record.subject else { return }
        try await reject(
            action.id, record.steward, record.run, reason: "approval_\(record.status.rawValue)",
            approval: record.id)
    }

    private func execute(_ request: ExecutionRequest) async throws -> ExecutionOutcome {
        let outcome = await executor.execute(request)
        switch outcome {
        case .succeeded(let output):
            try await append(
                ActionEventType.executed, request.steward, request.run, .system,
                ActionExecuted(
                    action: request.action.id, approval: request.approval, output: output))
        case .failed(let error, let output):
            try await append(
                ActionEventType.failed, request.steward, request.run, .system,
                ActionFailed(
                    action: request.action.id, approval: request.approval, output: output,
                    error: error))
        }
        return outcome
    }

    private func reject(
        _ action: String, _ steward: StewardID, _ run: RunID, reason: String,
        approval: ApprovalID? = nil
    ) async throws {
        try await append(
            ActionEventType.rejected, steward, run, .system,
            ActionRejected(action: action, approval: approval, reason: reason))
    }

    private func append(
        _ type: String, _ steward: StewardID, _ run: RunID, _ actor: RuntimeActor,
        _ payload: some Encodable
    ) async throws {
        _ = try await sink.append(
            RuntimeEventDraft(
                type: type, steward: steward, run: run, actor: actor,
                payload: try Payload.encode(payload)))
    }
}
