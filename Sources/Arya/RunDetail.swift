import AryaCore
import AryaLedger
import Foundation

/// A decision as the app shows it: the choice and why.
public typealias DecisionSummary = RunDetail.Decision

/// One run with its decisions and the disposition of each proposed action, as `arya run` and
/// the run view show it. Built from the run's ledger events.
public struct RunDetail: Sendable, Hashable, Codable {
    /// One decision from `run/result`.
    public struct Decision: Sendable, Hashable, Codable {
        public var id: String
        public var choice: String
        public var rationale: String?
        /// One line a person reads: the steward's `why`, else its rationale.
        public var why: String? = nil
    }

    /// What happened to one proposed action.
    public enum Disposition: String, Sendable, Hashable, Codable {
        /// Proposed in a rehearsal, or not yet disposed.
        case proposed
        /// Waiting for a person; see `approval`.
        case held
        /// Executed (by policy or after approval).
        case executed
        /// Executed and failed.
        case failed
        /// Refused by policy, or its approval was denied or expired.
        case rejected
    }

    /// One proposed action.
    public struct Action: Sendable, Hashable, Codable {
        public var id: String
        public var kind: String
        public var binding: String?
        public var target: String?
        public var rationale: String?
        /// Policy's verdict: `auto`, `ask`, or `deny`, and why.
        public var policy: String
        public var policyReason: String
        public var disposition: Disposition
        /// The approval it waits or waited on.
        public var approval: String?
        /// Output from the executor, or the rejection reason or error.
        public var detail: String?
        /// The steward's one-line why and the adapter's risk hint (`low`, `medium`, `high`).
        public var why: String? = nil
        /// Runtime's resolved risk when recorded (decision 0037), else the adapter's hint.
        public var risk: String? = nil
        /// True when `executed` was only a draft: a dry run changed nothing ("Drafted, not
        /// sent").
        public var drafted: Bool? = nil
    }

    /// The run's summary fields.
    public var run: RunSummary
    /// The input text the run worked on.
    public var input: String
    public var decisions: [Decision]
    /// Actions in result order.
    public var actions: [Action]
}

extension Workspace {
    /// A run with decisions and per-action dispositions, or `nil` if no run has this id.
    public func run(_ id: String) async throws -> RunDetail? {
        guard let record = try await runBook().records[RunID(unchecked: id)] else { return nil }
        var detail = RunDetail(
            run: RunSummary(record), input: record.input, decisions: [], actions: [])
        let own = try facadeState().byRun[RunID(unchecked: id)] ?? []
        for event in own { try RunDetailFolder.apply(event, to: &detail) }
        let recorded = RecordedResults(own)
        let run = RunID(unchecked: id)
        for index in detail.decisions.indices {
            let decision = detail.decisions[index]
            detail.decisions[index].why =
                recorded.decision(decision.id, run: run)?.why ?? decision.rationale
        }
        for index in detail.actions.indices {
            let wire = recorded.action(detail.actions[index].id, run: run)
            detail.actions[index].why = wire?.why ?? detail.actions[index].rationale
            detail.actions[index].risk = detail.actions[index].risk ?? wire?.risk?.rawValue
        }
        return detail
    }
}

/// Folds one run's events into a `RunDetail`.
enum RunDetailFolder {
    static func apply(_ event: Event, to detail: inout RunDetail) throws {
        switch event.type {
        case .runDecision:
            let body = try event.payload(as: RunDecision.self).decision
            detail.decisions.append(
                .init(id: body.id, choice: body.choice, rationale: body.rationale))
        case .actionProposed:
            let body = try event.payload(as: ActionProposed.self)
            detail.actions.append(
                .init(
                    id: body.action.id, kind: body.action.kind, binding: body.action.binding,
                    target: body.action.target, rationale: body.action.rationale,
                    policy: body.disposition.rawValue, policyReason: body.reason,
                    disposition: .proposed, risk: body.risk?.rawValue))
        case .approvalRequested:
            let body = try event.payload(as: ApprovalRequested.self)
            guard let action = body.action else { return }
            update(&detail, action.id) {
                $0.disposition = .held
                $0.approval = body.approval.rawValue
            }
        case .actionExecuted:
            let body = try event.payload(as: ActionExecuted.self)
            update(&detail, body.action) {
                $0.disposition = .executed
                $0.drafted = body.dryRun == true ? true : nil
                $0.detail = try? body.output.map { try CanonicalJSON.string($0) }
            }
        case .actionFailed:
            let body = try event.payload(as: ActionFailed.self)
            update(&detail, body.action) {
                $0.disposition = .failed
                $0.detail = body.error
            }
        case .actionRejected:
            let body = try event.payload(as: ActionRejected.self)
            update(&detail, body.action) {
                $0.disposition = .rejected
                $0.detail = body.reason
            }
        default:
            return
        }
    }

    private static func update(
        _ detail: inout RunDetail, _ action: String, _ change: (inout RunDetail.Action) -> Void
    ) {
        guard let index = detail.actions.lastIndex(where: { $0.id == action }) else { return }
        change(&detail.actions[index])
    }
}
