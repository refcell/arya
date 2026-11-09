import AryaDesign
import SwiftUI

/// A run read top to bottom: its one-line summary, the message it started from, one quiet line
/// per step, tool calls and actions as one-line mono rows that expand on click, and an approval
/// inline with everything needed to decide it.
struct RunThread: View {
    var stream: RunStream
    var now: Date
    var context: StepContext
    /// Run controls (More, Run now…) at the right end of the top line.
    var accessory = AnyView(EmptyView())

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s4) {
            header
            if let store = context.store { FeatureWriteErrorLine(store: store) }
            if let input = stream.input {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("Input").aryaText(AryaFont.overline, AryaColor.inkFaint)
                    Text(input).aryaText(AryaFont.body, AryaColor.inkMuted).textSelection(.enabled)
                }
            }
            LazyVStack(alignment: .leading, spacing: AryaSpace.s1) {
                ForEach(RunThreadText.visible(stream.steps)) { step in
                    if case .action(let action) = step.kind,
                        case .awaitingApproval(let approval) = action.outcome
                    {
                        InlineApproval(
                            action: action, approval: approval, source: stream.input,
                            texts: context.store?.approvalTexts[approval],
                            primary: approval == stream.pendingApprovals.first,
                            decide: context.decide
                        )
                        .padding(.vertical, AryaSpace.s3)
                    } else {
                        ThreadLine(step: step, now: now)
                    }
                }
            }
        }
    }

    /// Trigger and start time only; the summary is the last step, shown once.
    private var header: some View {
        HStack(alignment: .center, spacing: AryaSpace.s2) {
            if case .running = stream.status { StatusDot(.running) }
            Text(RunThreadText.meta(stream)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            Spacer(minLength: AryaSpace.s3)
            accessory
        }
    }
}

/// One step as one quiet line: time, then text. Tool calls and actions are mono with a mark
/// and expand on click.
private struct ThreadLine: View {
    var step: StreamStep
    var now: Date
    @AryaState private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(StreamStepText.clock(step.at))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .help(FeatureTime.absolute(step.at))
                line
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { if expandable { open.toggle() } }
            if open { detail.padding(.leading, AryaSize.stepGutter * 2) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StreamStepText.spoken(step, now: now))
        .accessibilityAddTraits(expandable ? .isButton : [])
    }

    private var expandable: Bool {
        switch step.kind {
        case .toolCall: return true
        case .action(let action): return action.routine != nil || !action.paramLines.isEmpty
        default: return false
        }
    }

    @ViewBuilder private var line: some View {
        switch step.kind {
        case .toolCall(let call):
            MarkGlyph(mark: StreamStepText.mark(step.kind))
            Text(call.tool).aryaText(AryaFont.mono, AryaColor.ink)
            Text(RunThreadText.toolMeta(call)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        case .action(let action):
            MarkGlyph(mark: StreamStepText.mark(step.kind))
            Text("\(action.kind) \(action.target)").aryaText(AryaFont.mono, AryaColor.ink)
                .lineLimit(1).truncationMode(.middle)
            if let note = RunThreadText.actionNote(action) {
                Text(note).aryaText(
                    AryaFont.monoSmall,
                    RunThreadText.failed(action) ? AryaColor.negative : AryaColor.inkFaint)
            }
            if ["ask", "deny"].contains(action.policy),
                let policy = AryaPolicy(rawValue: action.policy)
            {
                PolicyChip(policy)
            }
        case .decision(_, let choice, let rationale, _):
            Text(choice).aryaText(AryaFont.bodyStrong, AryaColor.ink)
            Text(rationale).aryaText(AryaFont.body, AryaColor.inkMuted)
        case .error, .failed:
            Text(StreamStepText.title(step.kind)).aryaText(AryaFont.body, AryaColor.negative)
        case .finished:
            MarkGlyph(mark: .ok)
            Text(StreamStepText.title(step.kind)).aryaText(AryaFont.body, AryaColor.ink)
        case .thinking, .status, .started:
            Text(StreamStepText.title(step.kind)).aryaText(AryaFont.body, AryaColor.inkFaint)
        case .message:
            Text(StreamStepText.title(step.kind)).aryaText(AryaFont.body, AryaColor.ink)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var detail: some View {
        switch step.kind {
        case .toolCall(let call):
            VStack(alignment: .leading, spacing: AryaSpace.s2) {
                MachineText(call.input.prettyText)
                if let output = call.output { MachineText(output.prettyText) }
            }
        case .action(let action):
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                ForEach(action.paramLines, id: \.self) {
                    Text($0).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
                if let run = action.routine { RoutineRunBody(run: run) }
            }
        default: EmptyView()
        }
    }
}

/// A check, cross, live dot, or open circle.
struct MarkGlyph: View {
    var mark: WorkMark

    var body: some View {
        switch mark {
        case .ok:
            Image(systemName: "checkmark").aryaText(AryaFont.monoSmall, AryaColor.positive)
                .accessibilityLabel("done")
        case .failed:
            Image(systemName: "xmark").aryaText(AryaFont.monoSmall, AryaColor.negative)
                .accessibilityLabel("failed")
        case .running: StatusDot(.running)
        case .waiting: StatusDot(.waiting)
        case .idle:
            Image(systemName: "circle").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                .accessibilityLabel("proposed")
        }
    }
}

/// An approval inside the transcript, unboxed: what would be written in full, what it answers,
/// where it goes, why it was held, and the two choices.
struct InlineApproval: View {
    var action: ProposedActionStep
    var approval: String
    var source: String?
    /// The workspace's policy sentence and change line, shown verbatim.
    var texts: FeatureApprovalText?
    /// The first waiting approval takes Return and Escape.
    var primary: Bool
    var decide: (FeatureWrite) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AryaSpace.s3) {
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                Text("Needs your approval").aryaText(AryaFont.overline, AryaColor.inkMuted)
                Text(RunThreadText.approvalTitle(action)).aryaText(
                    AryaFont.bodyStrong, AryaColor.ink)
                if let content = action.content {
                    Text(content).aryaText(AryaFont.body, AryaColor.ink).textSelection(.enabled)
                } else {
                    if let change = texts?.change {
                        Text(change).aryaText(AryaFont.mono, AryaColor.ink)
                            .textSelection(.enabled)
                    } else {
                        ForEach(action.paramLines, id: \.self) {
                            Text($0).aryaText(AryaFont.mono, AryaColor.ink)
                        }
                    }
                }
                if let source {
                    VStack(alignment: .leading, spacing: AryaSpace.s1) {
                        Text(RunThreadText.sourceLabel(action)).aryaText(
                            AryaFont.overline, AryaColor.inkFaint)
                        Text(source).aryaText(AryaFont.body, AryaColor.inkMuted).textSelection(
                            .enabled)
                    }
                }
                if !action.rationale.isEmpty {
                    Text("Why: \(action.rationale)").aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
                if let policy = texts?.policy, !policy.isEmpty {
                    Text(policy).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
                Text(RunThreadText.approvalMeta(action)).aryaText(
                    AryaFont.monoSmall, AryaColor.inkFaint)
                HStack(spacing: AryaSpace.s3) {
                    Spacer()
                    deny
                    approve
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval: \(RunThreadText.approvalTitle(action))")
    }

    @ViewBuilder private var deny: some View {
        let button = Button("Deny") { decide(.deny(approval: approval, reason: "")) }
            .buttonStyle(.aryaTertiary)
        if primary { button.keyboardShortcut(.cancelAction) } else { button }
    }

    @ViewBuilder private var approve: some View {
        let button = Button(RunThreadText.approveLabel(action)) {
            decide(.approve(approval: approval))
        }
        .buttonStyle(.aryaPrimary)
        if primary { button.keyboardShortcut(.defaultAction) } else { button }
    }
}

/// Text for the run thread, kept apart from layout so it can be tested.
enum RunThreadText {
    /// Steps worth a line: the start is the header, so it is left out; the finish stays as
    /// the one place the summary appears.
    static func visible(_ steps: [StreamStep]) -> [StreamStep] {
        steps.filter { step in
            if case .started = step.kind { return false }
            return true
        }
    }

    /// "started by manual · 14:54:19".
    /// "started manually", "started on schedule", "started by a message".
    static func started(_ trigger: String) -> String {
        switch trigger {
        case "manual": "started manually"
        case "interval", "schedule": "started on schedule"
        case "message": "started by a message"
        case "case": "started by a rehearsal case"
        default: "started by \(trigger)"
        }
    }

    static func meta(_ stream: RunStream, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if case .started(let trigger) = stream.steps.first?.kind {
            parts.append(started(trigger))
        }
        if let first = stream.steps.first {
            parts.append(StreamStepText.clock(first.at, timeZone: timeZone))
        }
        return parts.joined(separator: " · ")
    }

    /// "via tracker · live · 1.2 s".
    static func toolMeta(_ call: ToolCallStep) -> String {
        var parts = [call.binding.map { "via \($0)" }, call.source.map(StreamStepText.sourceWord)]
        if call.output == nil { parts.append("running") }
        if let seconds = call.durationSeconds { parts.append(FeatureTime.duration(seconds)) }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    static func failed(_ action: ProposedActionStep) -> Bool {
        switch action.outcome {
        case .failed, .rejected, .denied: return true
        default: return false
        }
    }

    /// A short note after an action's line; nil when the mark says it all (it ran).
    static func actionNote(_ action: ProposedActionStep) -> String? {
        switch action.outcome {
        case .executed, .proposed, .awaitingApproval: return nil
        case .approved: return "approved, running"
        case .failed(let error): return "failed: \(error)"
        case .rejected(let rule):
            return "blocked by \(rule.replacingOccurrences(of: ":", with: " "))"
        case .denied(_, let reason): return reason.isEmpty ? "denied" : "denied: \(reason)"
        }
    }

    /// "In reply to" for messages the action answers, else "From message".
    static func sourceLabel(_ action: ProposedActionStep) -> String {
        ["reply", "comment", "message", "send"].contains(action.kind)
            ? "In reply to" : "From message"
    }

    /// "Approve and reply"; a question is just "Approve".
    static func approveLabel(_ action: ProposedActionStep) -> String {
        action.kind == "question" ? "Approve" : "Approve and \(action.kind)"
    }

    /// "Reply to inbox:MSG-201".
    static func approvalTitle(_ action: ProposedActionStep) -> String {
        let verb = action.kind.prefix(1).uppercased() + action.kind.dropFirst()
        return action.target.isEmpty ? verb : "\(verb) \(preposition(action.kind)) \(action.target)"
    }

    /// "via inbox · risk medium"; why it was held is the workspace's sentence.
    static func approvalMeta(_ action: ProposedActionStep) -> String {
        var parts: [String] = []
        if let binding = action.binding { parts.append("via \(binding)") }
        parts.append("risk \(action.risk.rawValue)")
        return parts.joined(separator: " · ")
    }

    private static func preposition(_ kind: String) -> String {
        switch kind {
        case "reply", "comment", "message", "send": return "to"
        default: return "on"
        }
    }
}

/// Machine output as plain mono text that wraps within the pane and can be selected.
struct MachineText: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
