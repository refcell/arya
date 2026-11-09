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
    var approveLabel: String { "Approve and \(kind)" }
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
    static func build(events: [FeatureEvent], steward: String? = nil) -> ApprovalQueue {
        var actions: [String: FeatureEvent] = [:]
        var items: [String: ApprovalItem] = [:]
        var order: [String] = []
        for event in events where steward == nil || event.steward == steward {
            let p = event.payload
            switch event.type {
            case "action.proposed":
                actions[actionKey(event.run, p["id"]?.string ?? event.id)] = event
            case "approval.requested":
                guard let id = p["id"]?.string else { continue }
                let actionID = p["action"]?.string ?? ""
                let proposed = actions[actionKey(event.run, actionID)]
                items[id] = item(id: id, actionID: actionID, request: event, proposed: proposed)
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

    private static func actionKey(_ run: String?, _ action: String) -> String {
        "\(run ?? "")/\(action)"
    }

    private static func item(
        id: String, actionID: String, request: FeatureEvent, proposed: FeatureEvent?
    ) -> ApprovalItem {
        let p = proposed?.payload ?? [:]
        let kind = p["kind"]?.string ?? "action"
        let target = p["target"]?.string ?? ""
        return ApprovalItem(
            id: id, actionID: actionID, kind: kind, target: target,
            summary: request.payload["summary"]?.string ?? p["summary"]?.string
                ?? "\(kind) \(target)",
            rationale: p["rationale"]?.string ?? "", steward: request.steward, run: request.run,
            requestedAt: request.at)
    }

    private static func decision(_ event: FeatureEvent) -> ApprovalDecision {
        let verdict: ApprovalDecision.Verdict
        switch event.type {
        case "approval.granted": verdict = .granted
        case "approval.denied": verdict = .denied
        default: verdict = .expired
        }
        return ApprovalDecision(
            verdict: verdict, actor: event.actor, reason: event.payload["reason"]?.string ?? "",
            at: event.at)
    }
}
