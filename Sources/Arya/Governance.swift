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
