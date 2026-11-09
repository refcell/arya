import AryaDesign
import SwiftUI

/// The one place the interface asks for a person: an action waiting for approve or deny.
struct ApprovalCard: View {
    var item: ApprovalItem
    var now: Date
    var onApprove: () -> Void
    var onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text("\(item.kind) \(item.target)").aryaText(AryaFont.mono, AryaColor.ink)
            Text(item.summary).aryaText(AryaFont.bodyStrong, AryaColor.ink)
            if !item.rationale.isEmpty {
                Text(item.rationale).aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text(ApprovalText.meta(item, now: now))
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    .help(FeatureTime.absolute(item.requestedAt))
                Spacer(minLength: AryaSpace.s3)
                Button("Deny", action: onDeny)
                    .buttonStyle(FeatureSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(item.approveLabel, action: onApprove)
                    .buttonStyle(FeaturePrimaryButtonStyle())
            }
        }
        .padding(AryaSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AryaColor.accentWash)
        .overlay(alignment: .leading) {
            Rectangle().fill(AryaColor.accent).frame(width: AryaSize.approvalEdge)
        }
        .clipShape(RoundedRectangle(cornerRadius: AryaRadius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval, \(item.summary)")
        .accessibilityAction(named: Text(item.approveLabel), onApprove)
        .accessibilityAction(named: Text("Deny"), onDeny)
    }
}

/// Text for approvals, kept apart from layout so it can be tested.
enum ApprovalText {
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
