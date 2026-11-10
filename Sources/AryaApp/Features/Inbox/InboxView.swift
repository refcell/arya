import AryaDesign
import SwiftUI

/// The inbox: questions runs addressed to person bindings, answered here with text.
struct InboxView: View {
    @ObservedObject var store: FeatureStore

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading the inbox.", guidance: "Reading questions from the ledger.")
        case .failed(let message):
            EmptyState(
                "The inbox could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            content(InboxList.build(events: events))
        }
    }

    @ViewBuilder
    private func content(_ list: InboxList) -> some View {
        if list.items.isEmpty {
            EmptyState(
                "No questions for people.",
                guidance: "When a steward asks a person binding something, it appears here.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AryaSpace.s4) {
                    FeatureWriteErrorLine(store: store)
                    ForEach(list.people, id: \.self) { person in
                        let items = list.items(for: person)
                        VStack(alignment: .leading, spacing: AryaSpace.s3) {
                            Text(InboxText.person(person, waiting: items.filter(\.isWaiting).count))
                                .aryaText(AryaFont.heading, AryaColor.ink)
                            ForEach(items) { item in
                                InboxRow(store: store, item: item)
                                AryaHairline()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AryaSpace.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AryaColor.canvas)
        }
    }
}

/// One question: the text, where it came from, and an answer field while it waits.
private struct InboxRow: View {
    @ObservedObject var store: FeatureStore
    var item: InboxItem
    @AryaState private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text(item.question).aryaText(AryaFont.body, AryaColor.ink)
            Text(meta).aryaText(AryaFont.caption, AryaColor.inkFaint)
            if item.isWaiting {
                CharterTextField(placeholder: "Answer for the steward", text: $answer)
                HStack(spacing: AryaSpace.s3) {
                    Spacer()
                    Button("Decline") {
                        Task {
                            await store.perform(
                                .deny(approval: item.id, reason: "Declined from the inbox."))
                        }
                    }
                    .buttonStyle(.aryaTertiary)
                    Button("Send answer") {
                        Task {
                            if await store.perform(.answer(approval: item.id, text: answer)) {
                                answer = ""
                            }
                        }
                    }
                    .buttonStyle(.aryaPrimary)
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text(InboxText.state(item.state)).aryaText(AryaFont.body, AryaColor.inkMuted)
            }
        }
    }

    private var meta: String {
        [item.steward, item.run, FeatureTime.relative(item.asked, now: store.now)]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
