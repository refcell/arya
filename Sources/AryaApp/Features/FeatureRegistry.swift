import AryaDesign
import SwiftUI

/// The seam between the shell and the feature views. The shell calls these two functions;
/// the app-views lane replaces each placeholder with its real view. Keep signatures stable.
@MainActor
enum FeatureRegistry {
    /// The view for a steward tab.
    @ViewBuilder
    static func view(for tab: StewardTab, context: FeatureContext) -> some View {
        switch tab {
        case .stream:
            if let store = context.store, let run = context.run?.id ?? context.runs.first?.id {
                RunStreamView(store: store, run: run)
            } else {
                EmptyState(
                    "No runs yet.",
                    guidance: "A run starts when a routine fires or you start one by hand.")
            }
        case .changes:
            EmptyState("No changes proposed.", guidance: "Proposals to the charter appear here.")
        case .ledger:
            EmptyState(
                "The ledger is empty.", guidance: "Every event this steward records appears here.")
        case .memory:
            EmptyState(
                "No memory yet.", guidance: "Notes the steward keeps between runs appear here.")
        case .routines:
            EmptyState("No routines yet.", guidance: "Routines the steward writes appear here.")
        case .rehearsals:
            EmptyState("No rehearsals yet.", guidance: "Rehearse the charter against a casebook.")
        }
    }

    /// The approval queue across all stewards.
    @ViewBuilder
    static func approvals(_ context: FeatureContext) -> some View {
        let approvals = context.model.approvals
        if let store = context.store {
            ApprovalQueueView(store: store)
        } else if approvals.isEmpty {
            EmptyState(
                "Nothing is waiting for you.",
                guidance: "Approvals appear here when a steward asks.")
        } else {
            ScrollView {
                VStack(spacing: AryaSpace.s4) {
                    ForEach(approvals) { approval in
                        ApprovalCard(
                            action: [approval.actionKind, approval.target].compactMap { $0 }
                                .joined(separator: " "),
                            summary: approval.kind == .question
                                ? "A question" : "Approve this action",
                            rationale: approval.text,
                            context: "\(approval.steward) · \(approval.run)",
                            approveLabel: approval.kind == .question
                                ? "Answer yes" : "Approve and run",
                            onDeny: { Task { await context.model.deny(approval.id) } },
                            onApprove: { Task { await context.model.approve(approval.id) } })
                    }
                }
                .frame(maxWidth: AryaSize.readingWidth)
                .padding(AryaSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
