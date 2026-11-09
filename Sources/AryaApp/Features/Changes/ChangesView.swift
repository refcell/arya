import AryaDesign
import SwiftUI

/// The Changes tab: proposals to a steward's charter and routines, their gate results, and
/// accept, reject, and override, each recorded with the local user as actor.
struct ChangesView: View {
    @ObservedObject var store: FeatureStore
    var steward: String?

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading changes.", guidance: "Reading proposals from the ledger.")
        case .failed(let message):
            EmptyState(
                "Changes could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            content(ChangeList.build(events: events, steward: steward))
        }
    }

    @ViewBuilder
    private func content(_ list: ChangeList) -> some View {
        if list.open.isEmpty && list.closed.isEmpty {
            EmptyState(
                "No proposals yet.",
                guidance: "A change to the charter or a routine waits here until its gate passes.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AryaSpace.s6) {
                    FeatureWriteErrorLine(store: store)
                    if !list.open.isEmpty { section("Open", list.open) }
                    if !list.closed.isEmpty { section("Closed", list.closed) }
                }
                .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
                .padding(AryaSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AryaColor.canvas)
        }
    }

    private func section(_ title: String, _ items: [ProposalItem]) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            Text(title).aryaText(AryaFont.heading, AryaColor.ink)
            ForEach(items) { item in
                ProposalRow(item: item) { write in Task { await store.perform(write) } }
                AryaHairline()
            }
        }
    }
}

private struct ProposalRow: View {
    var item: ProposalItem
    var decide: (FeatureWrite) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(item.title).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                Spacer(minLength: AryaSpace.s2)
                Text(ChangesText.meta(item)).aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            if !item.reason.isEmpty {
                Text(item.reason).aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            gateLine
            if item.isOpen {
                actions
            } else {
                Text(ChangesText.state(item.state)).aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var gateLine: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(spacing: AryaSpace.s2) {
                if let gate = item.gate { StatusBadge(gate.passed ? .passed : .failed) }
                Text(ChangesText.gate(item.gate)).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .monospacedDigit()
            }
            if let regressions = ChangesText.regressions(item.gate) {
                Text(regressions).aryaText(AryaFont.monoSmall, AryaColor.negative)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: AryaSpace.s3) {
            Spacer()
            Button("Reject") { decide(.rejectProposal(item.id, reason: "")) }
                .buttonStyle(.aryaSecondary)
            if item.canOverride {
                Button("Override and accept") {
                    decide(.overrideProposal(item.id, reason: "accepted over a failed gate"))
                }
                .buttonStyle(.aryaSecondary)
                .help("Accept although the gate failed. The override is recorded with your name.")
            }
            Button("Accept") { decide(.acceptProposal(item.id)) }
                .buttonStyle(.aryaPrimary)
                .disabled(!item.canAccept)
        }
    }
}
