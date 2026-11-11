import AryaDesign
import SwiftUI

/// Needs you in two panes (app-shell layout over app-views' parts): a dense queue on the left,
/// oldest first, with risk tone, the action in one sentence, the steward, and its age; the
/// selected approval in full on the right (the change, why, earlier decisions on its target,
/// the run's last steps, and Approve, Deny, Correct with their keys). j/k move, A approves,
/// D denies, C opens the run to correct it.
struct ApprovalQueueView: View {
    @ObservedObject var store: FeatureStore
    /// Limits the queue to one steward; nil shows every steward's approvals.
    var steward: String?
    /// The selected approval, shared with the inspector when the shell passes one.
    var selection: Binding<String?>? = nil
    /// Opens an approval's run thread (↩, Correct, the run link); nil where navigation is
    /// not available.
    var openRun: ((String, String) -> Void)? = nil

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading approvals.", guidance: "Reading the ledger.")
        case .failed(let message):
            EmptyState(
                "Approvals could not be loaded.", guidance: message,
                actionTitle: "Retry", action: { Task { await store.reload() } })
        case .loaded(let events):
            content(ApprovalQueue.build(events: events, steward: steward), events: events)
        }
    }

    @AryaState private var localSelection: String?
    private var selected: String? {
        get { selection?.wrappedValue ?? localSelection }
        nonmutating set {
            if let selection {
                selection.wrappedValue = newValue
            } else {
                localSelection = newValue
            }
        }
    }

    /// The high-risk approval waiting on "Approve anyway" after A.
    @AryaState private var confirming: ApprovalItem?
    @FocusState private var focused: Bool

    /// The queue column's width.
    static let queueWidth: CGFloat = 320

    @ViewBuilder
    private func content(_ queue: ApprovalQueue, events: [FeatureEvent]) -> some View {
        let keys = NeedsYouKeys(pending: queue.pending, selected: selected)
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AryaSpace.s3) {
                    queueHeader(queue)
                    if queue.pending.isEmpty {
                        Text("Nothing needs you right now.")
                            .aryaText(AryaFont.body, AryaColor.inkMuted)
                    } else {
                        rows(queue.pending, events: events, current: keys.current?.id)
                        NeedsYouHints()
                    }
                    if !queue.decided.isEmpty { decided(queue.decided) }
                }
                .padding(.horizontal, AryaSpace.s3)
                .padding(.vertical, AryaSpace.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: Self.queueWidth)
            AryaHairline(.vertical)
            ScrollView {
                VStack(alignment: .leading, spacing: AryaSpace.s4) {
                    FeatureWriteErrorLine(store: store)
                    if let current = keys.current {
                        detail(current, events: events)
                            .id(current.id)
                            .transition(.opacity)
                    } else {
                        Text("When a steward holds an action for a person, it waits here.")
                            .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    }
                }
                .padding(AryaSpace.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(AryaMotion.panel, value: keys.current?.id)
            }
        }
        .background(AryaColor.canvas)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(characters: NeedsYouKeys.handled) { press in
            switch NeedsYouKeys.action(for: press.characters) {
            case .next?: move(keys.step(1))
            case .previous?: move(keys.step(-1))
            case .approve?: if let item = keys.current { approve(item) }
            case .deny?: if let item = keys.current { decide(.deny(approval: item.id, reason: "")) }
            case .correct?: if let item = keys.current { correct(item) }
            case nil: return .ignored
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard let item = keys.current, let run = item.run, let steward = item.steward,
                let openRun
            else { return .ignored }
            openRun(run, steward)
            return .handled
        }
        .onKeyPress(.downArrow) {
            move(keys.step(1)); return .handled
        }
        .onKeyPress(.upArrow) {
            move(keys.step(-1)); return .handled
        }
        .confirmationDialog(
            confirming.map(NeedsYouKeys.confirmTitle) ?? "", isPresented: confirmBinding
        ) {
            Button("Approve") {
                if let item = confirming { decide(.approve(approval: item.id)) }
                confirming = nil
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text("This action is high risk and may not be reversible.")
        }
    }

    /// The selection glides to the next row.
    private func move(_ id: String?) {
        withAnimation(AryaMotion.quick) { selected = id }
    }

    private func correct(_ item: ApprovalItem) {
        guard let run = item.run, let steward = item.steward else { return }
        openRun?(run, steward)
    }

    private func queueHeader(_ queue: ApprovalQueue) -> some View {
        // The page title above names the screen; the column carries the count.
        HStack(alignment: .firstTextBaseline) {
            Text("Queue").aryaText(AryaFont.label, AryaColor.inkFaint)
            Spacer()
            Text("\(queue.pending.count) waiting · oldest first")
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
        }
    }

    private func rows(_ items: [ApprovalItem], events: [FeatureEvent], current: String?)
        -> some View
    {
        let names = StewardNames.build(events: events)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                NeedsYouRow(
                    item: item, stewardName: item.steward.map { names[$0] ?? $0 },
                    now: store.now, isSelected: item.id == current
                ) {
                    move(item.id)
                }
                .aryaArrival(store.now.timeIntervalSince(item.requestedAt) < 30)
            }
        }
    }

    /// The selected approval in full.
    @ViewBuilder
    private func detail(_ current: ApprovalItem, events: [FeatureEvent]) -> some View {
        let detail = NeedsYouDetail.build(item: current, events: events)
        InlineApproval(
            action: detail.action, approval: current.id, source: detail.source,
            texts: store.approvalTexts[current.id], primary: false,
            decide: decide, showsKeys: true,
            correct: current.run == nil || openRun == nil ? nil : { correct(current) })
        AryaHairline()
        ApprovalInspector(store: store, approval: current.id, openRun: openRun, showsPolicy: false)
        if current.kind != "question" {
            ApproversLine(events: events, steward: current.steward, kind: current.kind)
        }
        if let run = current.run {
            NeedsYouRunSteps(steps: NeedsYouRunSteps.lines(events: events, run: run))
        }
        if current.kind == "routine",
            let subject = RoutineApprovalSubject.find(events: events, approval: current.id)
        {
            RoutineApprovalDetail(store: store, subject: subject)
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    /// A approves at once, except high-risk actions, which ask first.
    private func approve(_ item: ApprovalItem) {
        if NeedsYouKeys.needsConfirm(item) {
            confirming = item
        } else {
            decide(.approve(approval: item.id))
        }
    }

    private func decided(_ items: [ApprovalItem]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                ForEach(items.prefix(20)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        Text("\(item.kind) \(item.target)").aryaText(
                            AryaFont.mono, AryaColor.inkMuted
                        )
                        .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: AryaSpace.s2)
                        if let decision = item.decision {
                            Text(ApprovalText.verdict(decision, now: store.now))
                                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        }
                    }
                }
            }
            .padding(.top, AryaSpace.s2)
        } label: {
            Text("Recent decisions").aryaText(AryaFont.overline, AryaColor.inkFaint)
        }
    }

    private func decide(_ write: FeatureWrite) {
        Task { await store.perform(write) }
    }
}

/// One pending item, two lines: a risk dot and the action in one sentence, then the steward,
/// the kind and target in mono, and how long it has waited.
private struct NeedsYouRow: View {
    var item: ApprovalItem
    var stewardName: String?
    var now: Date
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Circle().fill(tone).frame(width: AryaSize.statusDot, height: AryaSize.statusDot)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                VStack(alignment: .leading, spacing: 0) {
                    // What and where first; ids wrap rather than lose their middle.
                    Text(title)
                        .aryaText(AryaFont.mono, isSelected ? AryaColor.ink : AryaColor.inkMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // The steward's name is never clipped; the reason gets its own line, cut
                    // at a word, with the whole of it in the tooltip.
                    if let stewardName {
                        Text(stewardName)
                            .aryaText(AryaFont.caption, AryaColor.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let why {
                        Text(AryaTrim.words(why, limit: Self.whyLimit))
                            .aryaText(AryaFont.caption, AryaColor.inkFaint)
                            .lineLimit(1)
                            .help(why)
                    }
                }
                Spacer(minLength: AryaSpace.s2)
                Text(AryaTime.label(item.requestedAt, now: now, style: .short))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            .padding(.vertical, AryaSpace.s1)
            .padding(.horizontal, AryaSpace.s2)
            .background(
                isSelected ? AryaColor.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: AryaRadius.small)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            [item.summary, stewardName, "\(risk.rawValue) risk"].compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Characters of the reason that fit the queue column on one caption line.
    static let whyLimit = 44

    private var risk: ActionRisk { ActionRisk(kind: item.kind) }

    private var title: String {
        item.kind == "question"
            ? item.summary : ActionWords.sentence(kind: item.kind, target: item.target)
    }

    /// The reason, else the summary; nil when both are empty.
    private var why: String? {
        let text = item.rationale.isEmpty ? item.summary : item.rationale
        return text.isEmpty || item.kind == "question" ? nil : ActionWords.humanize(text)
    }

    /// High risk reads negative, medium warning, low faint; questions faint.
    private var tone: Color {
        guard item.kind != "question" else { return AryaColor.inkFaint }
        switch risk {
        case .high: return AryaColor.negative
        case .medium: return AryaColor.warning
        case .low: return AryaColor.inkFaint
        }
    }
}

/// The run's newest steps under an approval: clock in the gutter, one line each.
struct NeedsYouRunSteps: View {
    var steps: [(time: String, text: String)]

    static let limit = 6

    static func lines(events: [FeatureEvent], run: String) -> [(time: String, text: String)] {
        let stream = RunStream.build(events: events, run: run)
        return RunThreadText.visible(stream.steps).suffix(limit).map {
            (StreamStepText.clock($0.at), StreamStepText.title($0.kind))
        }
    }

    var body: some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("Run so far").aryaText(AryaFont.label, AryaColor.inkFaint)
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        Text(step.time).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        Text(step.text).aryaText(AryaFont.caption, AryaColor.inkMuted)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

/// What the approval block needs for a queue item: the run's projected action (with its
/// params) and the input the run started from.
enum NeedsYouDetail {
    static func build(item: ApprovalItem, events: [FeatureEvent])
        -> (action: ProposedActionStep, source: String?)
    {
        let stream = item.run.map { RunStream.build(events: events, run: $0) }
        let found = stream?.steps.lazy.compactMap { step -> ProposedActionStep? in
            if case .action(let action) = step.kind, action.actionID == item.actionID,
                !item.actionID.isEmpty
            {
                return action
            }
            return nil
        }.first
        let action =
            found
            ?? ProposedActionStep(
                actionID: item.actionID, kind: item.kind,
                target: item.kind == "question" ? "" : item.target, summary: item.summary,
                rationale: item.rationale, policy: "ask",
                outcome: .awaitingApproval(approval: item.id),
                params: item.kind == "question" ? ["text": .string(item.summary)] : [:])
        return (action, stream?.input)
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

/// Steward names from their charters in the ledger, newest charter last, by steward id.
enum StewardNames {
    static func build(events: [FeatureEvent]) -> [String: String] {
        var names: [String: String] = [:]
        for event in events {
            guard let steward = event.steward,
                let name = event.payload["charter"]?["name"]?.string, !name.isEmpty
            else { continue }
            names[steward] = name
        }
        return names
    }
}

/// Keyboard rules for Needs you: j/k (or the arrows) move, A approves, D denies.
struct NeedsYouKeys {
    enum Action: Equatable { case next, previous, approve, deny, correct }

    var pending: [ApprovalItem]
    var selected: String?

    static let handled = CharacterSet(charactersIn: "jkadcJKADC")

    static func action(for characters: String) -> Action? {
        switch characters.lowercased() {
        case "j": .next
        case "k": .previous
        case "a": .approve
        case "d": .deny
        case "c": .correct
        default: nil
        }
    }

    /// The selected item, else the oldest.
    var current: ApprovalItem? { pending.first { $0.id == selected } ?? pending.first }

    /// The id one step away from the current item, clamped to the list.
    func step(_ delta: Int) -> String? {
        guard !pending.isEmpty else { return nil }
        let index = pending.firstIndex { $0.id == current?.id } ?? 0
        return pending[min(max(index + delta, 0), pending.count - 1)].id
    }

    static func needsConfirm(_ item: ApprovalItem) -> Bool {
        item.kind != "question" && ActionRisk(kind: item.kind) == .high
    }

    /// "Approve refund ORDER-1043?".
    static func confirmTitle(_ item: ApprovalItem) -> String {
        "Approve \(item.kind) \(item.target)?"
    }
}

/// Keycap hints under the queue.
private struct NeedsYouHints: View {
    var body: some View {
        HStack(spacing: AryaSpace.s2) {
            hint("j/k", "move")
            hint("A", "approve")
            hint("D", "deny")
            hint("C", "correct")
            hint("↩", "run")
        }
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: AryaSpace.s1) {
            Keycap(keys)
            Text(label).aryaText(AryaFont.caption, AryaColor.inkFaint)
                .lineLimit(1).fixedSize()
        }
    }
}
