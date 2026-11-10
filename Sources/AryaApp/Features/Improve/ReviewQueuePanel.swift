import AryaDesign
import SwiftUI

/// The review queue on Improve: progress toward ready, then the next case with what the
/// steward would have done next to what the person did, and Agree, Skip, or Correct.
struct ReviewQueuePanel: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    var queue: FeatureReviewQueue
    @AryaState private var choice = ""
    @AryaState private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text("REVIEW").aryaText(AryaFont.overline, AryaColor.inkFaint)
                Text(queue.progressText)
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted).monospacedDigit()
                Spacer(minLength: AryaSpace.s2)
                ProgressView(value: Double(queue.reviewed), total: Double(max(queue.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(AryaColor.accent)
                    .frame(width: 96)
                    .accessibilityLabel(queue.progressText)
            }
            if let next = queue.next {
                item(next)
            } else {
                Text("Every case is reviewed.").aryaText(AryaFont.body, AryaColor.inkMuted)
            }
        }
    }

    private func item(_ next: FeatureReviewQueue.Item) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                if let matches = next.matches { MarkGlyph(mark: matches ? .ok : .failed) }
                Text(next.id).aryaText(AryaFont.mono, AryaColor.ink)
                Text(next.input).aryaText(AryaFont.body, AryaColor.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            HStack(alignment: .top, spacing: AryaSpace.s4) {
                labeled("Would have done", next.wouldHave)
                labeled("Person did", next.personDid)
            }
            if !next.difference.isEmpty {
                Text(next.difference).aryaText(AryaFont.monoSmall, AryaColor.negative)
            }
            if !next.source.isEmpty {
                Text(next.source).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Button("Agree") { review(next, "agree") }
                    .buttonStyle(.aryaSecondary)
                    .help("What the person did is right; the case stays as it is.")
                Button("Skip") { review(next, "skip") }
                    .buttonStyle(.aryaTertiary)
                    .help("Leave this case for later.")
                TextField("Should have chosen", text: $choice)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.mono, AryaColor.ink)
                    .frame(maxWidth: AryaSize.readingWidth / 4)
                TextField("Note (optional)", text: $note)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.body, AryaColor.ink)
                Button("Correct") { correct(next) }
                    .buttonStyle(.aryaSecondary)
                    .disabled(choice.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Set the choice this case expects; the note is kept as memory.")
            }
        }
        .padding(.vertical, AryaSpace.s1)
    }

    private func labeled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title).aryaText(AryaFont.overline, AryaColor.inkFaint)
            Text(text).aryaText(AryaFont.mono, AryaColor.ink).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func review(_ next: FeatureReviewQueue.Item, _ verdict: String) {
        Task {
            await store.perform(.reviewCase(steward: steward, caseID: next.id, verdict: verdict))
        }
    }

    private func correct(_ next: FeatureReviewQueue.Item) {
        let picked = choice.trimmingCharacters(in: .whitespaces)
        let version = queue.casebookVersion
        Task {
            var expected: FeatureJSON =
                (try? await store.workspace.caseExpected(casebook: version, caseID: next.id))
                ?? nil ?? [:]
            if case .object(var members) = expected {
                members["decisions"] = [["choice": .string(picked)]]
                expected = .object(members)
            }
            let write = FeatureWrite.correctCase(
                CaseCorrection(
                    steward: steward, casebook: version, caseID: next.id, text: note,
                    expected: expected, rehearsal: queue.rehearsal, run: nil))
            if await store.perform(write) {
                choice = ""
                note = ""
            }
        }
    }
}
