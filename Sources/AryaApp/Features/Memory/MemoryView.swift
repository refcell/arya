import AryaDesign
import SwiftUI

/// What a steward keeps between runs: each note with where it came from, and Retract to hide
/// it from future runs. Retracted notes stay visible on request, since the ledger keeps them.
struct MemoryView: View {
    @ObservedObject var store: FeatureStore
    var steward: String?
    @AryaState private var showRetracted = false

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading memory.", guidance: "Reading notes from the ledger.")
        case .failed(let message):
            EmptyState(
                "Memory could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            content(MemoryList.build(events: events, steward: steward))
        }
    }

    @ViewBuilder
    private func content(_ list: MemoryList) -> some View {
        if list.live.isEmpty && list.retracted.isEmpty {
            EmptyState(
                "No memory yet.",
                guidance: "Notes appear when a run keeps something or a person corrects a case.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AryaSpace.s4) {
                    FeatureWriteErrorLine(store: store)
                    if list.live.isEmpty {
                        Text("Every note has been retracted.")
                            .aryaText(AryaFont.body, AryaColor.inkMuted)
                    }
                    ForEach(list.live) { item in
                        MemoryRow(item: item, now: store.now) {
                            Task { await store.perform(.retractMemory(note: item.id, reason: "")) }
                        }
                        AryaHairline()
                    }
                    if !list.retracted.isEmpty { retracted(list.retracted) }
                }
                .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
                .padding(AryaSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AryaColor.canvas)
        }
    }

    private func retracted(_ items: [MemoryItem]) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            Button(showRetracted ? "Hide retracted" : "Show retracted (\(items.count))") {
                showRetracted.toggle()
            }
            .buttonStyle(.aryaTertiary)
            if showRetracted {
                ForEach(items) { item in
                    MemoryRow(item: item, now: store.now, retract: nil)
                }
            }
        }
    }
}

private struct MemoryRow: View {
    var item: MemoryItem
    var now: Date
    var retract: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text(item.text)
                    .aryaText(AryaFont.body, item.isLive ? AryaColor.ink : AryaColor.inkFaint)
                Spacer(minLength: AryaSpace.s3)
                if let retract {
                    Button("Retract", action: retract)
                        .buttonStyle(.aryaSecondary)
                        .help("Hide this note from future runs. The ledger keeps it.")
                }
            }
            HStack(spacing: AryaSpace.s2) {
                ForEach(item.tags, id: \.self) { Chip($0) }
                Text(MemoryText.provenance(item, now: now))
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    .help(FeatureTime.absolute(item.addedAt))
            }
            if let retraction = item.retraction {
                Text(MemoryText.retraction(retraction))
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
            }
            Text(item.id).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        }
        .accessibilityElement(children: .contain)
    }
}
