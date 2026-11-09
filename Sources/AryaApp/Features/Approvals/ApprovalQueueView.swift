import AryaDesign
import SwiftUI

/// The approval queue: pending cards oldest first, then a short record of recent decisions.
struct ApprovalQueueView: View {
    @ObservedObject var store: FeatureStore
    /// Limits the queue to one steward; nil shows every steward's approvals.
    var steward: String?

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading approvals.", guidance: "Reading the ledger.")
        case .failed(let message):
            EmptyState(
                "Approvals could not be loaded.", guidance: message,
                actionTitle: "Retry", action: { Task { await store.reload() } })
        case .loaded(let events):
            content(ApprovalQueue.build(events: events, steward: steward))
        }
    }

    @ViewBuilder
    private func content(_ queue: ApprovalQueue) -> some View {
        if queue.pending.isEmpty && queue.decided.isEmpty {
            EmptyState(
                "Nothing to approve.",
                guidance: "When a steward asks before acting, its request waits here.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AryaSpace.s4) {
                    FeatureWriteErrorLine(store: store)
                    if queue.pending.isEmpty {
                        Text("Nothing waiting. Recent decisions are below.")
                            .aryaText(AryaFont.body, AryaColor.inkMuted)
                    }
                    ForEach(queue.pending) { item in
                        ApprovalItemCard(item: item, now: store.now, decide: decide, store: store)
                    }
                    if !queue.decided.isEmpty { decided(queue.decided) }
                }
                .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
                .padding(AryaSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AryaColor.canvas)
        }
    }

    private func decided(_ items: [ApprovalItem]) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            Text("Decided").aryaText(AryaFont.heading, AryaColor.ink)
                .padding(.top, AryaSpace.s4)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("\(item.kind) \(item.target)").aryaText(AryaFont.mono, AryaColor.ink)
                    if let decision = item.decision {
                        Text(ApprovalText.verdict(decision, now: store.now))
                            .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    }
                }
            }
        }
    }

    private func decide(_ write: FeatureWrite) {
        Task { await store.perform(write) }
    }
}

/// The last write error, stated with its cause and next step, with a way to dismiss it.
struct FeatureWriteErrorLine: View {
    @ObservedObject var store: FeatureStore

    var body: some View {
        if let message = store.writeError {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text(message).aryaText(AryaFont.body, AryaColor.negative)
                Spacer(minLength: AryaSpace.s3)
                Button("Dismiss") { store.dismissWriteError() }
                    .buttonStyle(.aryaTertiary)
            }
        }
    }
}
