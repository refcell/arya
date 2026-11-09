import AryaDesign
import SwiftUI

/// An approval item as the design system's approval card, recording the person's answer.
struct ApprovalItemCard: View {
    var item: ApprovalItem
    var now: Date
    var decide: (FeatureWrite) -> Void
    /// When set, a `routine` action shows the routine version it would run.
    var store: FeatureStore? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            card
            if item.kind == "routine", let store, case .loaded(let events) = store.state,
                let subject = RoutineApprovalSubject.find(events: events, approval: item.id)
            {
                RoutineApprovalDetail(store: store, subject: subject)
            }
        }
    }

    private var card: some View {
        ApprovalCard(
            action: "\(item.kind) \(item.target)", summary: item.summary,
            rationale: item.rationale, context: ApprovalText.meta(item, now: now),
            approveLabel: item.approveLabel,
            onDeny: { decide(.deny(approval: item.id, reason: "")) },
            onApprove: { decide(.approve(approval: item.id)) }
        )
        .help(FeatureTime.absolute(item.requestedAt))
        .accessibilityLabel("Approval, \(item.summary)")
    }
}

/// Text for approvals, kept apart from layout so it can be tested.
enum ApprovalText {
    /// The card's one-sentence summary of a held action: "Wants to assign tracker:ISSUE-7."
    static func summary(kind: String, target: String) -> String {
        target.isEmpty ? "Wants to \(kind)." : "Wants to \(kind) \(target)."
    }

    /// "st_triage · run_0001 · 2m ago".
    static func meta(_ item: ApprovalItem, now: Date) -> String {
        [item.steward, item.run, FeatureTime.relative(item.requestedAt, now: now)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "Approved by local · 1m ago", "Denied by local: on leave", "Expired".
    static func verdict(_ decision: ApprovalDecision, now: Date) -> String {
        let when = FeatureTime.relative(decision.at, now: now)
        let who = decision.actor.id
        switch decision.verdict {
        case .granted: return "Approved by \(who) · \(when)"
        case .denied:
            let reason = decision.reason.isEmpty ? "" : ": \(decision.reason)"
            return "Denied by \(who)\(reason) · \(when)"
        case .expired: return "Expired · \(when)"
        }
    }
}
