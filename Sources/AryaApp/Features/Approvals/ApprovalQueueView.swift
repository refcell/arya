import AryaDesign
import SwiftUI

/// The approval queue: pending cards oldest first, then a short record of recent decisions.
struct ApprovalQueueView: View {
    @ObservedObject var store: FeatureStore
    /// Limits the queue to one steward; nil shows every steward's approvals.
    var steward: String?
    /// The selected approval, shared with the inspector when the shell passes one.
    var selection: Binding<String?>? = nil

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

    @ViewBuilder
    private func content(_ queue: ApprovalQueue, events: [FeatureEvent]) -> some View {
        let keys = NeedsYouKeys(pending: queue.pending, selected: selected)
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                FeatureWriteErrorLine(store: store)
                if queue.pending.isEmpty {
                    Text("Nothing needs you right now.").aryaText(AryaFont.body, AryaColor.inkMuted)
                } else {
                    pending(queue.pending, events: events)
                }
                if !queue.pending.isEmpty { NeedsYouHints() }
                if !queue.decided.isEmpty { decided(queue.decided) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AryaSpace.s4)
            .padding(.vertical, AryaSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AryaColor.canvas)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(characters: NeedsYouKeys.handled) { press in
            switch NeedsYouKeys.action(for: press.characters) {
            case .next?: selected = keys.step(1)
            case .previous?: selected = keys.step(-1)
            case .approve?: if let item = keys.current { approve(item) }
            case .deny?: if let item = keys.current { decide(.deny(approval: item.id, reason: "")) }
            case nil: return .ignored
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            selected = keys.step(1); return .handled
        }
        .onKeyPress(.upArrow) {
            selected = keys.step(-1); return .handled
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

    @ViewBuilder
    private func pending(_ items: [ApprovalItem], events: [FeatureEvent]) -> some View {
        let current = items.first { $0.id == selected } ?? items[0]
        if items.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                let names = StewardNames.build(events: events)
                ForEach(items) { item in
                    NeedsYouRow(
                        item: item, stewardName: item.steward.map { names[$0] ?? $0 },
                        now: store.now, isSelected: item.id == current.id
                    ) {
                        selected = item.id
                    }
                }
            }
            AryaHairline()
        }
        let detail = NeedsYouDetail.build(item: current, events: events)
        InlineApproval(
            action: detail.action, approval: current.id, source: detail.source,
            texts: store.approvalTexts[current.id], primary: true,
            decide: decide)
        if current.kind != "question" {
            ApproversLine(events: events, steward: current.steward, kind: current.kind)
        }
        if current.kind == "routine",
            let subject = RoutineApprovalSubject.find(events: events, approval: current.id)
        {
            RoutineApprovalDetail(store: store, subject: subject)
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

/// One pending item: what and where in mono, the steward, and how long it has waited.
private struct NeedsYouRow: View {
    var item: ApprovalItem
    var stewardName: String?
    var now: Date
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(item.kind == "question" ? item.summary : "\(item.kind) \(item.target)")
                    .aryaText(AryaFont.mono, isSelected ? AryaColor.ink : AryaColor.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: AryaSpace.s2)
                if let stewardName {
                    Text(stewardName).aryaText(AryaFont.caption, AryaColor.inkMuted)
                        .lineLimit(1)
                }
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    enum Action: Equatable { case next, previous, approve, deny }

    var pending: [ApprovalItem]
    var selected: String?

    static let handled = CharacterSet(charactersIn: "jkadJKAD")

    static func action(for characters: String) -> Action? {
        switch characters.lowercased() {
        case "j": .next
        case "k": .previous
        case "a": .approve
        case "d": .deny
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
            hint("↩", "approve")
            hint("A", "approve")
            hint("D", "deny")
        }
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: AryaSpace.s1) {
            Keycap(keys)
            Text(label).aryaText(AryaFont.caption, AryaColor.inkFaint)
        }
    }
}
