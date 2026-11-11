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
                    .tint(AryaColor.inkMuted)
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
                Text(ReviewText.difference(next.difference))
                    .aryaText(AryaFont.body, AryaColor.negative)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(next.difference)
            }
            if !next.source.isEmpty {
                Text(ReviewText.source(next.source, now: store.now))
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(next.source)
            }
            // The fields get their own row so their placeholders show whole.
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                TextField("Should have chosen", text: $choice)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.mono, AryaColor.ink)
                    .frame(maxWidth: .infinity)
                TextField("Note (optional)", text: $note)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.body, AryaColor.ink)
                    .frame(maxWidth: .infinity)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Button("Agree") { review(next, "agree") }
                    .buttonStyle(.aryaSecondary)
                    .help("What the person did is right; the case stays as it is.")
                Button("Skip") { review(next, "skip") }
                    .buttonStyle(.aryaTertiary)
                    .help("Leave this case for later.")
                Spacer(minLength: AryaSpace.s2)
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

/// The review card's workspace text in plain words.
enum ReviewText {
    /// "decisions[0].choice: expected account, got security" reads "Chose security; the
    /// person chose account". Other fields read "label: would be bug; the person had spam".
    static func difference(_ text: String) -> String {
        text.components(separatedBy: "; ").map { part in
            guard let colon = part.range(of: ": expected "),
                let got = part.range(of: ", got ", range: colon.upperBound..<part.endIndex)
            else { return part }
            let path = String(part[..<colon.lowerBound])
            let expected = String(part[colon.upperBound..<got.lowerBound])
            let actual = String(part[got.upperBound...])
            if path.hasSuffix("choice") {
                return "Chose \(actual); the person chose \(expected)"
            }
            let field = path.split(separator: ".").last.map(String.init) ?? path
            return "\(field): would be \(actual); the person had \(expected)"
        }.joined(separator: ". ")
    }

    /// "history history-export.json item MSG-120 by person:sam at 2026-10-09T09:00:00Z,
    /// reopened: Rerouted…" reads "MSG-120 · Sam · Oct 9 · reopened: Rerouted…".
    static func source(_ text: String, now: Date) -> String {
        // Only the workspace's `… by <who> at <timestamp>` shape is rewritten; anything else
        // shows as written.
        guard let by = text.range(of: " by "),
            let at = text.range(of: " at ", range: by.upperBound..<text.endIndex)
        else { return text }
        let after = text[at.upperBound...]
        let stamp = after.prefix { !$0.isWhitespace && $0 != "," }
        guard let date = AryaTime.parse(iso: String(stamp)) else { return text }
        let who = String(text[by.upperBound..<at.lowerBound])
        var parts: [String] = []
        if let item = text.range(of: " item ", range: text.startIndex..<by.lowerBound) {
            parts.append(String(text[item.upperBound..<by.lowerBound]))
        }
        parts.append(OutcomePeople.actor(who, names: [:]))
        parts.append(AryaTime.label(date, now: now))
        let tail = after.dropFirst(stamp.count).drop { $0 == "," || $0 == " " }
        if !tail.isEmpty { parts.append(String(tail)) }
        return parts.joined(separator: " · ")
    }
}
