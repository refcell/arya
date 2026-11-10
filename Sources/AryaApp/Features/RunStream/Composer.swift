import AryaDesign
import SwiftUI

/// What a person means by a message to a steward (decision 0039).
enum MessageIntent: String, CaseIterable, Hashable, Sendable {
    case ask
    case correct
    case handoff

    var label: String {
        switch self {
        case .ask: "Ask"
        case .correct: "Correct"
        case .handoff: "Hand off"
        }
    }
}

/// The one-line composer under a run thread: message the steward (↩), or start a run with the
/// text as its input (⌘↩). The intent menu says whether it is a question, a correction, or work
/// handed off.
struct Composer: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    @AryaState private var text = ""
    @AryaState private var intent = MessageIntent.ask
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AryaHairline()
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Menu(intent.label) {
                    ForEach(MessageIntent.allCases, id: \.self) { choice in
                        Button(choice.label) { intent = choice }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .aryaText(AryaFont.caption, AryaColor.inkMuted)
                .help("Ask a question, correct the steward, or hand off work")
                TextField(ComposerText.placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.body, AryaColor.ink)
                    .focused($focused)
                    .onSubmit { send() }
                // Holds ⌘↩ only; the keycap hint beside it is the visible label.
                Button(action: runNow) { EmptyView() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .accessibilityLabel("Run now with this text")
                Text(ComposerText.hints).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AryaSpace.s5)
            .padding(.vertical, AryaSpace.s2)
        }
        .background(AryaColor.canvas)
    }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard !empty else { return }
        let write = FeatureWrite.message(
            steward: steward, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            intent: intent)
        Task { if await store.perform(write) { text = "" } }
    }

    private func runNow() {
        guard !empty else { return }
        let write = FeatureWrite.startRun(
            steward: steward, input: text.trimmingCharacters(in: .whitespacesAndNewlines))
        Task { if await store.perform(write) { text = "" } }
    }
}

enum ComposerText {
    static let placeholder = "Ask, correct, or hand off…"
    static let hints = "↩ send  ⌘↩ run now"
}
