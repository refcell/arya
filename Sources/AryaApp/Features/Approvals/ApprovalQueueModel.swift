import Foundation

/// One approval request with the action it holds.
struct ApprovalItem: Identifiable, Hashable, Sendable {
    /// The approval id.
    var id: String
    var actionID: String
    var kind: String
    var target: String
    var summary: String
    var rationale: String
    var steward: String?
    var run: String?
    var requestedAt: Date
    var decision: ApprovalDecision?

    /// The primary button label, naming the effect: "Approve and assign".
    var approveLabel: String { kind == "question" ? "Approve" : "Approve and \(kind)" }
}

/// How a person (or time) answered an approval.
struct ApprovalDecision: Hashable, Sendable {
    enum Verdict: String, Hashable, Sendable {
        case granted, denied, expired
    }

    var verdict: Verdict
    var actor: FeatureActor
    var reason: String
    var at: Date
}

/// The approval queue: pending requests oldest first, and decided ones newest first.
struct ApprovalQueue: Hashable, Sendable {
    var pending: [ApprovalItem]
    var decided: [ApprovalItem]

    /// Projects approvals from the whole ledger, optionally for one steward.
    /// `approval.requested` is `{approval, kind, action?: ProposedAction, question?, to}`.
    static func build(events: [FeatureEvent], steward: String? = nil) -> ApprovalQueue {
        var items: [String: ApprovalItem] = [:]
        var order: [String] = []
        for event in events where steward == nil || event.steward == steward {
            let p = event.payload
            switch event.type {
            case "approval.requested":
                guard let id = p["approval"]?.string else { continue }
                items[id] = item(id: id, request: event)
                order.append(id)
            case "approval.granted", "approval.denied", "approval.expired":
                guard let id = p["approval"]?.string, items[id] != nil else { continue }
                items[id]?.decision = decision(event)
            default: continue
            }
        }
        let all = order.compactMap { items[$0] }
        return ApprovalQueue(
            pending: all.filter { $0.decision == nil },
            decided: all.filter { $0.decision != nil }.reversed())
    }

    private static func item(id: String, request: FeatureEvent) -> ApprovalItem {
        let p = request.payload
        if let question = p["question"]?.string, p["action"] == nil {
            return ApprovalItem(
                id: id, actionID: "", kind: "question", target: p["to"]?.string ?? "local",
                summary: question, rationale: "", steward: request.steward, run: request.run,
                requestedAt: request.at)
        }
        let action = p["action"] ?? [:]
        let kind = action["kind"]?.string ?? "action"
        let target = action["target"]?.string ?? ""
        return ApprovalItem(
            id: id, actionID: action["id"]?.string ?? "", kind: kind, target: target,
            summary: ApprovalText.summary(kind: kind, target: target),
            rationale: action["rationale"]?.string ?? "", steward: request.steward,
            run: request.run, requestedAt: request.at)
    }

    private static func decision(_ event: FeatureEvent) -> ApprovalDecision {
        let verdict: ApprovalDecision.Verdict
        switch event.type {
        case "approval.granted": verdict = .granted
        case "approval.denied": verdict = .denied
        default: verdict = .expired
        }
        return ApprovalDecision(
            verdict: verdict, actor: event.actor, reason: event.payload["note"]?.string ?? "",
            at: event.at)
    }
}
