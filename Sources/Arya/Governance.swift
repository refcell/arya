import AryaCore
import AryaLedger
import AryaRuntime
import Foundation

// Governance read models and checks (governance lane): who may approve what, and one policy
// summary per steward of the tools and actions its charter allows.

/// A steward's policy in one read: per binding, the tools a run may read and each action
/// kind with its disposition, risk, and approvers.
public struct PolicySummary: Sendable, Hashable, Codable {
    /// One action kind a binding allows.
    public struct Action: Sendable, Hashable, Codable {
        public var kind: String
        /// `auto`, `ask`, or `deny`, after rules and autonomy.
        public var decision: String
        /// The verdict's reason, for example `rule:reply` or `autonomy:act_low:medium`.
        public var reason: String
        /// `low`, `medium`, or `high`.
        public var risk: String
        /// Who may grant it when held; nil when anyone may.
        public var approvers: [String]?
        /// The approver rule's note.
        public var approverNote: String?
    }

    /// One binding and what it lets a run do.
    public struct Binding: Sendable, Hashable, Codable {
        public var id: String
        /// `mcp` or `person`.
        public var kind: String
        /// Tools a run may call (the tool allowlist).
        public var tools: [String]
        /// The binding server may use the network when sandboxed.
        public var network: Bool
        /// For people: the relay binding, nil for the local inbox.
        public var via: String?
        public var actions: [Action]
    }

    /// One `policy.approvers` rule.
    public struct ApproverLine: Sendable, Hashable, Codable {
        public var action: String
        public var binding: String?
        public var people: [String]
        public var note: String?
    }

    public var steward: String
    /// The autonomy level, nil when the policy alone decides.
    public var autonomy: String?
    /// The disposition for kinds no rule names.
    public var fallback: String
    public var bindings: [Binding]
    public var approvers: [ApproverLine]
}

extension PolicySummary {
    /// The summary of a charter's policy.
    init(_ charter: Charter) {
        let policy = ActionPolicy(charter: charter)
        steward = charter.id.rawValue
        autonomy = charter.autonomy?.rawValue
        fallback = charter.policy.default.rawValue
        approvers = charter.policy.approvers.map {
            ApproverLine(action: $0.action, binding: $0.binding, people: $0.people, note: $0.note)
        }
        bindings = charter.bindings.map { binding in
            let actions = binding.actions.map { kind in
                let verdict = policy.classify(PolicyAction(kind: kind, binding: binding.id))
                let rule = charter.policy.approverRule(forAction: kind, binding: binding.id)
                return Action(
                    kind: kind, decision: verdict.disposition.rawValue, reason: verdict.reason,
                    risk: policy.risk(of: PolicyAction(kind: kind, binding: binding.id)).rawValue,
                    approvers: rule?.people, approverNote: rule?.note)
            }
            return Binding(
                id: binding.id, kind: binding.kind.rawValue, tools: binding.read,
                network: binding.network, via: binding.via, actions: actions)
        }
    }
}

extension Workspace {
    /// The steward's policy summary from its live charter.
    public func policySummary(steward: String) async throws -> PolicySummary {
        PolicySummary(try await existing(steward).charter)
    }

    /// Records `approval.refused` and throws when `person` may not grant a pending action
    /// approval under the live charter's `policy.approvers`. Anything else (questions, decided
    /// or unknown approvals) is left to the grant itself.
    func checkApprover(_ id: String, person: String) async throws {
        let approval = ApprovalID(unchecked: id)
        guard let record = try await approvalQueue.book().records[approval],
            record.status == .pending, case .action(let action) = record.subject
        else { return }
        let charter = try await existing(record.steward.rawValue).charter
        guard case .refused(let rule) = charter.policy.authority(of: person, for: action) else {
            return
        }
        let name = rule.binding.map { "\(rule.action)@\($0)" } ?? rule.action
        let payload = ApprovalRefused(
            approval: approval, by: person, people: rule.people, rule: name, note: rule.note)
        _ = try await sink.append(
            RuntimeEventDraft(
                type: ApprovalRefused.type.rawValue, steward: record.steward, run: record.run,
                actor: .person(person),
                payload: try CanonicalJSON.decode(
                    JSONValue.self, from: try CanonicalJSON.encode(payload))))
        let who = rule.people.joined(separator: " or ")
        let why = rule.note.map { " (\($0))" } ?? ""
        throw WorkspaceError.rejected(
            "\(person) may not approve \(action.kind) actions; only \(who) may\(why)")
    }
}

extension Workspace {
    /// Asks arya to stop a running run on behalf of `person` (`run.abort.requested`). The
    /// process running it stops the adapter and executes nothing the run proposes; the run
    /// ends `stopped` (or fails `aborted`). When no live process holds the run, it is failed
    /// `aborted` here. Returns the run as the ledger now says; a run that was already handed
    /// to its process may still be running, so read it again for the end.
    public func abortRun(_ id: String, reason: String? = nil, as person: String = "local")
        async throws -> RunSummary
    {
        let run = RunID(unchecked: id)
        guard let record = try await runBook().records[run] else {
            throw WorkspaceError.notFound(id)
        }
        guard record.status == .running else {
            throw WorkspaceError.rejected("\(id) is already \(record.status.rawValue)")
        }
        let text = reason.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: RunAbortRequested.type.rawValue, steward: record.steward, run: run,
                actor: .person(person), payload: try Self.json(RunAbortRequested(reason: text))))
        if !leases.isHeld(run) {
            let failed = RunFailed(reason: "aborted", detail: "no process was running it")
            _ = try await sink.append(
                RuntimeEventDraft(
                    type: RunFailed.type.rawValue, steward: record.steward, run: run,
                    actor: .system, payload: try Self.json(failed)))
        }
        guard let now = try await runBook().records[run] else { throw WorkspaceError.notFound(id) }
        return RunSummary(now)
    }

    static func json(_ payload: some Encodable) throws -> JSONValue {
        try CanonicalJSON.decode(JSONValue.self, from: try CanonicalJSON.encode(payload))
    }
}

/// An executed action the charter's `policy.undo` says how to undo.
public struct UndoOption: Sendable, Hashable, Codable {
    public var run: String
    /// The executed action's id within the run.
    public var action: String
    public var kind: String
    public var binding: String?
    public var target: String?
    /// The compensating action kind.
    public var with: String
    /// The undo rule's note.
    public var note: String?
    /// The compensation already requested for it, if any (then it cannot be undone again).
    public var undoneBy: String?
}

/// What happened to a requested undo.
public struct UndoSummary: Sendable, Hashable, Codable {
    public var option: UndoOption
    /// The compensating action's disposition: `auto`, `ask`, or `deny`.
    public var decision: String
    /// The policy verdict's reason.
    public var reason: String
    /// The approval it waits on, for `ask`.
    public var approval: String?
    /// True when the compensation executed successfully.
    public var executed: Bool
}

extension Workspace {
    /// The run's executed actions that the live charter can undo, in execution order.
    public func undoOptions(run: String) async throws -> [UndoOption] {
        try await undoState(run).2
    }

    /// Undoes an executed action on behalf of `person`: records `action.undo.requested`, then
    /// proposes the compensating action (`undo:<id>`, same binding and target) through policy,
    /// so it runs, waits for approval, or is refused like any other action. Its params are
    /// `{undoes, params, previous}`: the action's id and params, and the params of the last
    /// action of the same kind and target executed before it (null when none).
    public func undoAction(
        run: String, action: String, reason: String? = nil, as person: String = "local"
    ) async throws -> UndoSummary {
        let (record, charter, options) = try await undoState(run)
        guard var option = options.first(where: { $0.action == action }) else {
            throw WorkspaceError.rejected("\(action) in \(run) is not an executed, undoable action")
        }
        if let done = option.undoneBy {
            throw WorkspaceError.rejected("\(action) in \(run) is already undone by \(done)")
        }
        let original = try await executedAction(record, action)
        let compensation = ProposedAction(
            id: "undo:\(action)", kind: option.with, binding: original.action.binding,
            target: original.action.target,
            params: [
                "undoes": .string(action), "params": original.action.params ?? .null,
                "previous": original.previous ?? .null,
            ],
            rationale: reason, why: "Undo \(original.action.kind) \(action)")
        let text = reason.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: ActionUndoRequested.type.rawValue, steward: record.steward, run: record.id,
                actor: .person(person),
                payload: try Self.json(
                    ActionUndoRequested(
                        action: action, compensation: compensation.id, reason: text))))
        let disposal = try await dispatcher.dispose(
            [compensation], charter: charter, run: record.id)
        option.undoneBy = compensation.id
        let executed: Bool =
            if case .succeeded? = disposal.first?.outcome { true } else { false }
        return UndoSummary(
            option: option, decision: disposal.first?.verdict.disposition.rawValue ?? "deny",
            reason: disposal.first?.verdict.reason ?? "",
            approval: disposal.first?.approval?.rawValue,
            executed: executed)
    }

    private func undoState(_ run: String) async throws -> (RunRecord, Charter, [UndoOption]) {
        guard let record = try await runBook().records[RunID(unchecked: run)] else {
            throw WorkspaceError.notFound(run)
        }
        let charter = try await existing(record.steward.rawValue).charter
        var proposed: [String: ProposedAction] = [:]
        var executed: [String] = []
        var undone: [String: String] = [:]
        for event in try reader.events(LedgerFilter(run: record.id)) {
            switch event.type {
            case .actionProposed:
                let action = try event.payload(as: ActionProposed.self).action
                proposed[action.id] = action
            case .actionExecuted: executed.append(try event.payload(as: ActionExecuted.self).action)
            case .actionUndoRequested:
                let body = try event.payload(as: ActionUndoRequested.self)
                undone[body.action] = body.compensation
            default: break
            }
        }
        let options = executed.compactMap { id -> UndoOption? in
            guard let action = proposed[id],
                let rule = charter.policy.undoRule(forAction: action.kind, binding: action.binding)
            else { return nil }
            return UndoOption(
                run: run, action: id, kind: action.kind, binding: action.binding,
                target: action.target, with: rule.with, note: rule.note, undoneBy: undone[id])
        }
        return (record, charter, options)
    }

    /// The executed action and the params of the last action of its kind and target that the
    /// steward executed before it.
    private func executedAction(_ record: RunRecord, _ id: String) async throws
        -> (action: ProposedAction, previous: JSONValue?)
    {
        let filter = LedgerFilter(
            steward: record.steward, types: [.actionProposed, .actionExecuted])
        var proposed: [String: ProposedAction] = [:]
        var history: [ProposedAction] = []
        for event in try reader.events(filter) {
            guard let run = event.run?.rawValue else { continue }
            if event.type == .actionProposed {
                let action = try event.payload(as: ActionProposed.self).action
                proposed["\(run):\(action.id)"] = action
                continue
            }
            let executedID = try event.payload(as: ActionExecuted.self).action
            guard let action = proposed["\(run):\(executedID)"] else { continue }
            if run == record.id.rawValue, executedID == id {
                let previous = history.last {
                    $0.kind == action.kind && $0.target == action.target
                }
                return (action, previous?.params)
            }
            history.append(action)
        }
        throw WorkspaceError.notFound(id)
    }
}
