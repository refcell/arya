import Arya
import AryaDesign
import SwiftUI

/// Defines a new steward as an outcome with guardrails, one question group per step, on the
/// window's canvas. One primary action (Continue, then Create steward); advanced fields sit
/// behind a disclosure. Creates through the facade's structured `createSteward`.
struct NewStewardSheet: View {
    @ObservedObject var store: FeatureStore
    /// Called with the steward's id once the facade recorded it (created, or change proposed).
    let created: (String) -> Void
    let cancel: () -> Void
    @AryaState private var draft: NewStewardDraft
    @AryaState private var step = NewStewardDraft.Step.outcome
    @AryaState private var tried = false
    @AryaState private var advanced = false
    @AryaState private var saving = false
    /// Step 0 (app-shell, Templates): start blank or from a template, before the steps.
    @AryaState private var starting: Bool

    init(
        store: FeatureStore, draft: NewStewardDraft = NewStewardDraft(),
        step: NewStewardDraft.Step = .outcome, startsWithTemplates: Bool = false,
        created: @escaping (String) -> Void, cancel: @escaping () -> Void
    ) {
        self.store = store
        self.created = created
        self.cancel = cancel
        var draft = draft
        draft.adopt(NewStewardCatalog(events: store.events))
        _draft = AryaState(initialValue: draft)
        _step = AryaState(initialValue: step)
        _starting = AryaState(
            initialValue: startsWithTemplates && draft.editing == nil
                && !store.workspace.templates().isEmpty)
    }

    private static let stepCount = NewStewardDraft.Step.allCases.count

    private var heading: String {
        let position = "\(step.rawValue + 1) of \(Self.stepCount)"
        guard let editing = draft.editing else { return "New steward · \(position)" }
        return "Edit charter v\(editing.baseVersion) · \(position)"
    }

    private var finalTitle: String { draft.editing == nil ? "Create steward" : "Propose change" }

    var body: some View {
        if starting { start } else { steps }
    }

    /// Step 0: the template rows and Blank; picking one prefills the steps.
    private var start: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("New steward · start").aryaText(AryaFont.label, AryaColor.inkFaint)
                Text("Start from").aryaText(AryaFont.heading, AryaColor.ink)
                Text("Pick a template to prefill every step, or start blank.")
                    .aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            ScrollView {
                NewStewardTemplatePicker(templates: store.workspace.templates(), choose: begin)
            }
            HStack(spacing: AryaSpace.s2) {
                Button("Cancel", action: cancel).buttonStyle(.aryaTertiary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("j/k move, ↩ pick").aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        }
        .padding(AryaSpace.s5)
        .frame(width: AryaSize.newStewardWidth)
        .frame(minHeight: AryaSize.newStewardHeight, alignment: .top)
        .background(AryaColor.canvas)
    }

    private func begin(_ template: StewardTemplate?) {
        if let template {
            var next = NewStewardDraft.template(template.draft)
            next.adopt(NewStewardCatalog(events: store.events))
            draft = next
        }
        step = .outcome
        starting = false
    }

    /// Two columns: the steps on the left, the current step on the right.
    private var steps: some View {
        HStack(alignment: .top, spacing: 0) {
            rail
                .frame(width: AryaSize.newStewardRail, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            AryaHairline(.vertical)
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text(step.title).aryaText(AryaFont.heading, AryaColor.ink)
                    Text(step.question).aryaText(AryaFont.body, AryaColor.inkMuted)
                }
                NewStewardFields(step: step, draft: $draft, advanced: $advanced)
                problems
                Spacer(minLength: 0)
                footer
            }
            .padding(AryaSpace.s5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: AryaSize.newStewardWidth)
        .frame(minHeight: AryaSize.newStewardHeight, alignment: .top)
        .background(AryaColor.canvas)
    }

    /// The heading, then each step: done ones checked and reachable, the current one in ink,
    /// later ones faint until every step before them is complete.
    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading).aryaText(AryaFont.overline, AryaColor.inkFaint)
                .padding(.bottom, AryaSpace.s3)
            ForEach(NewStewardDraft.Step.allCases, id: \.self) { item in railRow(item) }
            if draft.editing != nil {
                let changed = draft.changedFields()
                Text(
                    changed.isEmpty
                        ? "Nothing changed yet."
                        : "Changes "
                            + changed.joined(
                                separator: ", ")
                )
                .aryaText(AryaFont.caption, AryaColor.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AryaSpace.s3)
            }
        }
        .padding(AryaSpace.s5)
    }

    private var changesLine: String {
        let changed = draft.changedFields()
        return changed.isEmpty
            ? "Nothing changed yet." : "Changes " + changed.joined(separator: ", ")
    }

    private func railRow(_ item: NewStewardDraft.Step) -> some View {
        let current = item == step
        let open = reachable(item)
        let color: Color = current ? AryaColor.ink : open ? AryaColor.inkMuted : AryaColor.inkFaint
        return Button {
            if open { move(to: item) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(mark(item)).aryaText(AryaFont.mono, markColor(item))
                    .frame(width: AryaSize.newStewardCheck, alignment: .leading)
                Text(item.title).aryaText(current ? AryaFont.bodyStrong : AryaFont.body, color)
                Spacer(minLength: 0)
            }
            .frame(height: AryaSize.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!open)
        .accessibilityLabel("Step \(item.rawValue + 1), \(item.title)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func reachable(_ item: NewStewardDraft.Step) -> Bool {
        NewStewardDraft.Step.allCases.prefix(item.rawValue).allSatisfy {
            draft.problems($0).isEmpty
        }
    }

    private func mark(_ item: NewStewardDraft.Step) -> String {
        if item != step, item.rawValue < step.rawValue, draft.problems(item).isEmpty {
            return "✓"
        }
        return "\(item.rawValue + 1)"
    }

    private func markColor(_ item: NewStewardDraft.Step) -> Color {
        mark(item) == "✓" ? AryaColor.positive : item == step ? AryaColor.ink : AryaColor.inkFaint
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
            Button(step.next == nil ? finalTitle : "Continue", action: proceed)
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
        let write: FeatureWrite =
            draft.proposal().map(FeatureWrite.proposeCharter)
            ?? .createSteward(draft.stewardDraft())
        Task {
            let ok = await store.perform(write)
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
        labeled("Owner (who answers for it)") {
            CharterTextField(placeholder: "Alex", text: $draft.owner)
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
        // Metrics that must hold while the primary moves; a new steward's draft and an edit
        // both carry them.
        labeled("Must also hold (guardrail metrics)") {
            VStack(alignment: .leading, spacing: AryaSpace.s2) {
                ForEach($draft.guardrailMetrics) { $row in
                    HStack(alignment: .bottom, spacing: AryaSpace.s2) {
                        CharterTextField(
                            placeholder: "reopen_rate", text: $row.name, mono: true)
                        NewStewardChoice(
                            selection: $row.direction,
                            options: [("down", "at most"), ("up", "at least")])
                        CharterTextField(placeholder: "0.05", text: $row.target, mono: true)
                        Button("Remove") {
                            draft.guardrailMetrics.removeAll { $0.id == row.id }
                        }
                        .buttonStyle(.aryaTertiary)
                    }
                }
                Button("Add guardrail metric") { draft.addGuardrailMetric() }
                    .buttonStyle(.aryaTertiary)
            }
        }
    }

    @ViewBuilder private var guardrails: some View {
        labeled("It must never (one per line)") {
            CharterTextField(placeholder: "Never close a conversation.", text: $draft.guardrails)
        }
        labeled("By default it should") {
            NewStewardChoice(
                selection: Binding(
                    get: { draft.autonomy },
                    set: {
                        draft.autonomy = $0
                        draft.signOff = nil
                    }),
                options: NewStewardDraft.Autonomy.allCases.map { ($0, $0.label) })
            Text(draft.signOffHint).aryaText(AryaFont.caption, AryaColor.inkFaint)
        }
        labeled("Needs your sign-off") {
            if draft.actionKinds.isEmpty {
                Text("Turn on a connection to choose which of its actions need you.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach(draft.actionKinds, id: \.self) { kind in
                HStack(spacing: AryaSpace.s3) {
                    NewStewardCheck(
                        kind,
                        isOn: Binding(
                            get: { draft.needsSignOff(kind) },
                            set: { draft.setSignOff(kind, $0) }),
                        mono: true
                    )
                    .disabled(draft.never.contains(kind))
                    Text("\(draft.risk(kind)) risk")
                        .aryaText(
                            AryaFont.caption,
                            draft.never.contains(kind)
                                ? AryaColor.inkFaint : riskColor(draft.risk(kind))
                        )
                    Spacer()
                    Text(rowState(kind)).aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
                .frame(minHeight: AryaSize.controlHeight)
            }
        }
        if !draft.actionKinds.isEmpty {
            disclosure {
                labeled("Never allowed") {
                    ForEach(draft.actionKinds, id: \.self) { kind in
                        NewStewardCheck(
                            kind,
                            isOn: Binding(
                                get: { draft.never.contains(kind) },
                                set: { draft.setNever(kind, $0) }),
                            mono: true
                        )
                        .frame(minHeight: AryaSize.controlHeight)
                    }
                }
            }
        }
    }

    private func rowState(_ kind: String) -> String {
        if draft.never.contains(kind) { return "never" }
        return draft.needsSignOff(kind) ? "asks you" : "on its own"
    }

    private func riskColor(_ risk: String) -> Color {
        risk == "high" ? AryaColor.ink : AryaColor.inkFaint
    }

    @ViewBuilder private var connections: some View {
        labeled("Systems") {
            if draft.connections.isEmpty {
                Text("No systems yet. Add one under Advanced.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            ForEach($draft.connections) { $connection in
                HStack(spacing: AryaSpace.s3) {
                    NewStewardCheck(connection.id, isOn: $connection.isOn, mono: true)
                    Text(connection.actions.joined(separator: " · "))
                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                        .lineLimit(1)
                }
                .frame(minHeight: AryaSize.controlHeight)
            }
        }
        labeled("People") {
            ForEach($draft.people) { $person in
                HStack(spacing: AryaSpace.s3) {
                    CharterTextField(placeholder: "Name", text: $person.name)
                    NewStewardChoice(
                        selection: $person.channel, options: draft.channels.map { ($0, $0) })
                }
            }
            Button("Add person") { draft.addPerson() }
                .buttonStyle(.aryaTertiary)
        }
        disclosure {
            labeled("Add connection: a name and the command that serves it") {
                HStack(spacing: AryaSpace.s3) {
                    CharterTextField(placeholder: "tracker", text: $draft.customID, mono: true)
                        .frame(width: AryaSize.newStewardNumberWidth * 2)
                    CharterTextField(
                        placeholder: "tracker-mcp --stdio", text: $draft.customCommand, mono: true)
                }
            }
            labeled("Actions it offers") {
                CharterTextField(
                    placeholder: "comment, assign", text: $draft.customActions, mono: true)
            }
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
        if draft.editing != nil {
            labeled("Why this change") {
                CharterTextField(
                    placeholder: "One sentence for the proposal", text: $draft.whyChange)
            }
            if !draft.changedFields().isEmpty {
                Text(NewStewardDraft.changeLine(draft.changedFields()))
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        }
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
    static let newStewardHeight: CGFloat = 560
    /// The two-column sheet: the step rail plus a step wide enough for the sign-off table.
    static let newStewardWidth: CGFloat = 920
    static let newStewardRail: CGFloat = 220
    static let newStewardNumberWidth: CGFloat = 96
    static let newStewardCheck: CGFloat = 16
}

/// A quiet segmented choice drawn like `EffortSelector` (ink fill for the selection), so the
/// sheet shows no system accent color.
struct NewStewardChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        // The shared segmented control (app-shell, AryaDesign).
        AryaSegmented(options.map { ($0.0, $0.1) }, selection: selection) { selection = $0 }
    }
}

/// A checkbox in ink: a drawn box with a check and a label, no system accent color.
struct NewStewardCheck: View {
    let title: String
    @Binding var isOn: Bool
    var mono = false

    init(_ title: String, isOn: Binding<Bool>, mono: Bool = false) {
        self.title = title
        self._isOn = isOn
        self.mono = mono
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: AryaSpace.s2) {
                ZStack {
                    RoundedRectangle(cornerRadius: AryaRadius.small)
                        .fill(isOn ? AryaColor.ink : .clear)
                    RoundedRectangle(cornerRadius: AryaRadius.small)
                        .strokeBorder(isOn ? AryaColor.ink : AryaColor.ruleStrong, lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark")
                            .aryaText(AryaFont.monoSmall, AryaColor.canvas)
                    }
                }
                .frame(width: AryaSize.newStewardCheck, height: AryaSize.newStewardCheck)
                Text(title).aryaText(mono ? AryaFont.mono : AryaFont.body, AryaColor.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isButton)
    }
}
