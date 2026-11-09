import AryaDesign
import SwiftUI

/// Defines a new steward as an outcome with guardrails, one question group per step, on the
/// window's canvas. One primary action (Continue, then Create steward); advanced fields sit
/// behind a disclosure. Creates through the facade's structured `createSteward`.
struct NewStewardSheet: View {
    @ObservedObject var store: FeatureStore
    /// Called with the new steward's id once the facade recorded it.
    let created: (String) -> Void
    let cancel: () -> Void
    @AryaState private var draft: NewStewardDraft
    @AryaState private var step = NewStewardDraft.Step.outcome
    @AryaState private var tried = false
    @AryaState private var advanced = false
    @AryaState private var saving = false

    init(
        store: FeatureStore, draft: NewStewardDraft = NewStewardDraft(),
        step: NewStewardDraft.Step = .outcome,
        created: @escaping (String) -> Void, cancel: @escaping () -> Void
    ) {
        self.store = store
        self.created = created
        self.cancel = cancel
        _draft = AryaState(initialValue: draft)
        _step = AryaState(initialValue: step)
    }

    private static let stepCount = NewStewardDraft.Step.allCases.count

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("New steward · \(step.rawValue + 1) of \(Self.stepCount)")
                    .aryaText(AryaFont.overline, AryaColor.inkFaint)
                Text(step.title).aryaText(AryaFont.heading, AryaColor.ink)
                Text(step.question).aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            NewStewardFields(step: step, draft: $draft, advanced: $advanced)
            problems
            Spacer(minLength: 0)
            footer
        }
        .padding(AryaSpace.s5)
        .frame(width: AryaSize.readingWidth)
        .frame(minHeight: AryaSize.newStewardHeight)
        .background(AryaColor.canvas)
    }

    @ViewBuilder private var problems: some View {
        let shown = tried ? draft.problems(step) : []
        ForEach(shown, id: \.self) { problem in
            Text(problem).aryaText(AryaFont.caption, AryaColor.negative)
        }
        if let error = store.writeError, step.next == nil {
            Text(error).aryaText(AryaFont.caption, AryaColor.negative)
        }
    }

    private var footer: some View {
        HStack(spacing: AryaSpace.s2) {
            Button("Cancel", action: cancel).buttonStyle(.aryaTertiary)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if let previous = step.previous {
                Button("Back") { move(to: previous) }.buttonStyle(.aryaTertiary)
            }
            Button(step.next == nil ? "Create steward" : "Continue", action: proceed)
                .buttonStyle(.aryaPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(saving)
        }
    }

    private func move(to next: NewStewardDraft.Step) {
        tried = false
        advanced = false
        step = next
    }

    private func proceed() {
        tried = true
        guard draft.problems(step).isEmpty else { return }
        if let next = step.next { return move(to: next) }
        if let first = NewStewardDraft.Step.allCases.first(where: { !draft.problems($0).isEmpty }) {
            return move(to: first)
        }
        saving = true
        Task {
            let ok = await store.perform(.createSteward(draft.stewardDraft()))
            saving = false
            if ok { created(draft.stewardID) }
        }
    }
}

/// The fields of one step.
struct NewStewardFields: View {
    let step: NewStewardDraft.Step
    @Binding var draft: NewStewardDraft
    @Binding var advanced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            switch step {
            case .outcome: outcome
            case .metric: metric
            case .guardrails: guardrails
            case .connections: connections
            case .schedule: schedule
            }
        }
    }

    @ViewBuilder private var outcome: some View {
        labeled("Name") { CharterTextField(placeholder: "Support inbox triage", text: $draft.name) }
        labeled("Outcome") {
            CharterTextField(
                placeholder: "Every new message is labeled and routed within one hour.",
                text: $draft.outcome)
        }
        disclosure {
            labeled("Steward id") {
                Text(draft.stewardID).aryaText(AryaFont.mono, AryaColor.inkMuted)
            }
        }
    }

    @ViewBuilder private var metric: some View {
        labeled("Metric") {
            CharterTextField(placeholder: "routed_within_1h", text: $draft.metric, mono: true)
        }
        HStack(alignment: .bottom, spacing: AryaSpace.s3) {
            labeled("Target") {
                CharterTextField(placeholder: "0.95", text: $draft.target, mono: true)
            }
            labeled("Better when") {
                NewStewardChoice(
                    selection: $draft.direction, options: [("up", "higher"), ("down", "lower")])
            }
        }
        disclosure {
            labeled("Unit") {
                CharterTextField(placeholder: "ratio", text: $draft.unit, mono: true)
            }
        }
    }

    @ViewBuilder private var guardrails: some View {
        labeled("It must never (one per line)") {
            CharterTextField(placeholder: "Never close a conversation.", text: $draft.guardrails)
        }
        labeled("By default it should") {
            NewStewardChoice(
                selection: $draft.autonomy,
                options: NewStewardDraft.Autonomy.allCases.map { ($0, $0.label) })
        }
        labeled("Always needs your sign-off (actions, comma separated)") {
            CharterTextField(placeholder: "reply, assign", text: $draft.signOff, mono: true)
        }
        disclosure {
            labeled("Low-risk actions it takes on its own") {
                CharterTextField(placeholder: "label, route", text: $draft.automatic, mono: true)
            }
            labeled("Actions it may never take") {
                CharterTextField(placeholder: "close", text: $draft.never, mono: true)
            }
        }
    }

    @ViewBuilder private var connections: some View {
        labeled("Systems (one per line, id: command)") {
            CharterTextField(placeholder: "inbox: inbox-mcp", text: $draft.systems, mono: true)
        }
        labeled("People (one per line)") {
            CharterTextField(placeholder: "person:alex inbox", text: $draft.people, mono: true)
        }
    }

    @ViewBuilder private var schedule: some View {
        HStack(alignment: .bottom, spacing: AryaSpace.s3) {
            labeled("Wake every (minutes)") {
                CharterTextField(placeholder: "15", text: $draft.everyMinutes, mono: true)
                    .frame(width: AryaSize.newStewardNumberWidth)
            }
            NewStewardCheck("Also when a person writes to it", isOn: $draft.wakesOnMessage)
                .frame(height: AryaSize.controlHeight)
        }
        EffortSelector(
            selection: Binding(
                get: { AryaEffort(rawValue: draft.effort) ?? .medium },
                set: { draft.effort = $0.rawValue }))
        disclosure {
            labeled("Adapter profile") {
                CharterTextField(placeholder: "default", text: $draft.adapter, mono: true)
            }
        }
    }

    @ViewBuilder private func disclosure<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            advanced.toggle()
        } label: {
            HStack(spacing: AryaSpace.s1) {
                Text(advanced ? "▾" : "▸").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                Text("Advanced").aryaText(AryaFont.overline, AryaColor.inkFaint)
            }
        }
        .buttonStyle(.plain)
        if advanced { content() }
    }
}

/// The first-launch screen: what arya is in one sentence, and how to start.
struct FirstLaunchView: View {
    let newSteward: () -> Void
    let openDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            Text(Self.sentence).aryaText(AryaFont.body, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AryaSpace.s2) {
                Button("New steward", action: newSteward).buttonStyle(.aryaPrimary)
                Button("Open demo", action: openDemo).buttonStyle(.aryaTertiary)
            }
        }
        .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
        .padding(AryaSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    static let sentence =
        "arya runs stewards: agents that each own an outcome, rehearse on past work before "
        + "they go live, and ask you before anything sensitive."
}

extension AryaSize {
    static let newStewardHeight: CGFloat = 420
    static let newStewardNumberWidth: CGFloat = 96
}

/// A quiet segmented choice drawn like `EffortSelector` (ink fill for the selection), so the
/// sheet shows no system accent color.
struct NewStewardChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { AryaHairline(.vertical, color: AryaColor.ruleStrong) }
                segment(option.0, option.1)
            }
        }
        .frame(height: AryaSize.controlHeight)
        .clipShape(RoundedRectangle(cornerRadius: AryaRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: AryaRadius.small)
                .strokeBorder(AryaColor.ruleStrong, lineWidth: 1)
        }
        .fixedSize()
    }

    private func segment(_ value: Value, _ label: String) -> some View {
        let isSelected = value == selection
        return Button {
            selection = value
        } label: {
            Text(label)
                .aryaText(
                    isSelected ? AryaFont.bodyStrong : AryaFont.body,
                    isSelected ? AryaColor.canvas : AryaColor.inkMuted
                )
                .padding(.horizontal, AryaSpace.s3)
                .frame(maxHeight: .infinity)
                .background(isSelected ? AryaColor.ink : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A checkbox in ink: a mono mark and a label, no system accent color.
struct NewStewardCheck: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: AryaSpace.s2) {
                Text(isOn ? "[x]" : "[ ]").aryaText(AryaFont.mono, AryaColor.ink)
                Text(title).aryaText(AryaFont.body, AryaColor.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
