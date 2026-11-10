import AryaDesign
import SwiftUI

/// The charter editor: outcome, metric, guardrails, bindings, triggers, policy, and effort.
/// Saving records a proposal for the next version; the live charter never changes in place.
struct CharterEditorView: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    @AryaState private var draft: CharterDraft?
    @AryaState private var baseVersion = 0
    @AryaState private var reason = ""
    @AryaState private var proposed = false

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading the charter.", guidance: "Reading the steward's live version.")
        case .failed(let message):
            EmptyState(
                "The charter could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            if let live = LiveCharter.find(events: events, steward: steward) {
                editor(live)
            } else {
                EmptyState(
                    "No charter yet.", guidance: "Create the steward from a charter file first.")
            }
        }
    }

    private func editor(_ live: LiveCharter) -> some View {
        let binding = Binding(
            get: { draft ?? CharterDraft(charter: live.charter) },
            set: {
                draft = $0; proposed = false
            })
        return ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                Text("Charter v\(live.version)").aryaText(AryaFont.title, AryaColor.ink)
                CharterFields(draft: binding)
                footer(live, binding.wrappedValue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AryaSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AryaColor.canvas)
        .onAppear { if draft == nil { baseVersion = live.version } }
    }

    private func footer(_ live: LiveCharter, _ current: CharterDraft) -> some View {
        let changed = current.changedFields(from: live.charter)
        let issues = current.issues
        return VStack(alignment: .leading, spacing: AryaSpace.s3) {
            ForEach(issues, id: \.self) { Text($0).aryaText(AryaFont.body, AryaColor.negative) }
            FeatureWriteErrorLine(store: store)
            if proposed {
                Text("Proposed. It goes live once its gate passes; follow it in Changes.")
                    .aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            labeled("Why this change") {
                CharterTextField(placeholder: "One sentence for the proposal", text: $reason)
            }
            HStack(spacing: AryaSpace.s3) {
                Text(CharterText.title(changed)).aryaText(AryaFont.caption, AryaColor.inkFaint)
                Spacer()
                Button("Discard") {
                    draft = nil
                    reason = ""
                }
                .buttonStyle(.aryaSecondary)
                .disabled(changed.isEmpty)
                Button("Propose change") { propose(live, current, changed) }
                    .buttonStyle(.aryaPrimary)
                    .disabled(changed.isEmpty || !issues.isEmpty)
                    .help("Saving never edits the live charter; it records a proposal to rehearse.")
            }
        }
    }

    private func propose(_ live: LiveCharter, _ current: CharterDraft, _ changed: [String]) {
        let proposal = CharterProposal(
            steward: steward, baseVersion: draft == nil ? live.version : baseVersion,
            charter: current.charter, title: CharterText.title(changed),
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            if await store.perform(.proposeCharter(proposal)) {
                draft = nil
                reason = ""
                proposed = true
            }
        }
    }
}

/// A plain text field on the `sunken` fill.
struct CharterTextField: View {
    var placeholder: String
    @Binding var text: String
    var mono = false

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .aryaText(mono ? AryaFont.mono : AryaFont.body, AryaColor.ink)
            .padding(AryaSpace.s2)
            .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
    }
}

/// A caption label above its control.
@MainActor
func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: AryaSpace.s1) {
        Text(title).aryaText(AryaFont.caption, AryaColor.inkMuted)
        content()
    }
}
