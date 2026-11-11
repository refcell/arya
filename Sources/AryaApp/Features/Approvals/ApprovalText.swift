import AryaDesign
import SwiftUI

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

    /// "Approved by you · 1m ago", "Denied by Sam: on leave", "Expired".
    static func verdict(_ decision: ApprovalDecision, now: Date) -> String {
        let when = FeatureTime.relative(decision.at, now: now)
        let who = HumanText.actor(decision.actor)
        switch decision.verdict {
        case .granted: return "Approved by \(who) · \(when)"
        case .denied:
            let reason = decision.reason.isEmpty ? "" : ": \(decision.reason)"
            return "Denied by \(who)\(reason) · \(when)"
        case .expired: return "Expired · \(when)"
        }
    }
}
