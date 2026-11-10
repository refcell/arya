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
            if !stream.facts.text.isEmpty {
                Text("· " + stream.facts.text).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .lineLimit(1)
            }
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
    @AryaState private var toggled = false
    @Environment(\.crewOpenByDefault) private var crewOpen

    /// Crew lines can start open (offscreen snapshots); a click flips either default.
    private var open: Bool {
        guard case .delegated = step.kind, crewOpen else { return toggled }
        return !toggled
    }

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
            .onTapGesture { if expandable { toggled.toggle() } }
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
        case .delegated(let delegation): return delegation.refused == nil
        default: return false
        }
    }

    @ViewBuilder private var line: some View {
        switch step.kind {
        case .toolCall(let call):
            MarkGlyph(mark: StreamStepText.mark(step.kind))
            Text(call.tool).aryaText(AryaFont.mono, AryaColor.ink)
            if let argument = RunThreadText.argument(call.input) {
                Text(argument).aryaText(AryaFont.mono, AryaColor.inkMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let output = call.output, let result = RunThreadText.arrow(output) {
                Text("→ \(result)").aryaText(AryaFont.mono, AryaColor.inkMuted).lineLimit(1)
            }
            Text(RunThreadText.toolMeta(call)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        case .action(let action):
            MarkGlyph(mark: StreamStepText.mark(step.kind))
            Text("\(action.kind) \(action.target)").aryaText(AryaFont.mono, AryaColor.ink)
                .lineLimit(1).truncationMode(.middle)
            if let result = RunThreadText.arrow(action.params) {
                Text("→ \(result)").aryaText(AryaFont.mono, AryaColor.inkMuted).lineLimit(1)
            }
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
        case .delegated(let delegation):
            Text("↳").aryaText(AryaFont.mono, AryaColor.inkFaint).accessibilityHidden(true)
            MarkGlyph(mark: StreamStepText.mark(step.kind))
            Text(CrewText.line(delegation)).aryaText(
                AryaFont.body, delegation.refused == nil ? AryaColor.ink : AryaColor.inkMuted)
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
        case .delegated(let delegation):
            // The child's own steps, then its budget and result; AnyView breaks the recursion.
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                ForEach(delegation.childSteps) { child in
                    AnyView(ThreadLine(step: child, now: now))
                }
                if let budget = CrewText.budget(delegation) {
                    Text(budget).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                if delegation.childSteps.isEmpty, let result = CrewText.result(delegation) {
                    Text(result).aryaText(AryaFont.caption, AryaColor.inkMuted)
                }
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
                    } else if let summary = ActionSummary.sentence(action) {
                        Text(summary).aryaText(AryaFont.body, AryaColor.ink)
                            .textSelection(.enabled)
                    }
                }
                if !action.paramLines.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: AryaSpace.s1) {
                            ForEach(action.paramLines, id: \.self) {
                                Text($0).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                                    .textSelection(.enabled)
                            }
                        }
                    } label: {
                        Text("Details").aryaText(AryaFont.caption, AryaColor.inkMuted)
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

    /// A call's main argument in one short token: its first scalar input, e.g. `MSG-202`.
    static func argument(_ input: FeatureJSON) -> String? {
        guard let value = firstScalar(input), value.count <= 40 else { return nil }
        return value
    }

    /// A short result after an arrow: a scalar, or an object's one short scalar field
    /// (`billing` for `{label: billing}`); nil when the value needs the expanded view.
    static func arrow(_ value: FeatureJSON) -> String? {
        switch value {
        case .string(let text): return text.count <= 32 && !text.contains("\n") ? text : nil
        case .number, .bool: return value.compactText
        case .object(let members):
            let scalars = members.keys.sorted().compactMap { key -> String? in
                switch members[key] {
                case .string(let text)? where text.count <= 32 && !text.contains("\n"): text
                case .number?, .bool?: members[key]?.compactText
                default: nil
                }
            }
            return members.count == 1 ? scalars.first : nil
        default: return nil
        }
    }

    private static func firstScalar(_ value: FeatureJSON) -> String? {
        switch value {
        case .string(let text): return text
        case .number, .bool: return value.compactText
        case .object(let members):
            return members.keys.sorted().lazy.compactMap { key -> String? in
                switch members[key] {
                case .string(let text)?: text
                case .number?, .bool?: members[key]?.compactText
                default: nil
                }
            }.first
        default: return nil
        }
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
    @AryaState private var expanded = false

    init(_ text: String) { self.text = text }

    /// Lines shown before the rest folds behind "· N lines hidden".
    static let foldedLines = 4

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let folds = lines.count > Self.foldedLines + 1 && !expanded
        VStack(alignment: .leading, spacing: 0) {
            Text(folds ? lines.prefix(Self.foldedLines).joined(separator: "\n") : text)
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if lines.count > Self.foldedLines + 1 {
                Button(expanded ? "· fold" : MachineText.hidden(lines.count - Self.foldedLines)) {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "· 38 lines hidden".
    static func hidden(_ count: Int) -> String { "· \(count) lines hidden" }
}

/// One sentence for what an action would do, composed from its kind, target, and params when
/// the workspace gives no change line: "Refund 24.00 USD on ORDER-1043".
enum ActionSummary {
    private static let amountKeys = ["amount", "total", "value"]
    private static let referenceKeys = ["order", "order_id", "invoice", "ticket", "account"]
    private static let contentKeys: Set<String> = ["text", "body", "message", "comment"]

    static func sentence(_ action: ProposedActionStep) -> String? {
        guard case .object(let params) = action.params else { return nil }
        let verb =
            action.kind.prefix(1).uppercased()
            + action.kind.dropFirst()
            .replacingOccurrences(of: "_", with: " ")
        let reference = referenceKeys.lazy.compactMap { scalar(params[$0]) }.first
        let place = reference ?? (action.target.isEmpty ? nil : action.target)
        if let key = amountKeys.first(where: { params[$0] != nil }),
            let amount = money(params[key])
        {
            let currency = scalar(params["currency"]).map { " \($0)" } ?? ""
            return "\(verb) \(amount)\(currency)" + (place.map { " on \($0)" } ?? "")
        }
        let used = Set(referenceKeys + ["currency"]).union(contentKeys)
        let rest = params.keys.sorted().filter { !used.contains($0) }.compactMap { key in
            scalar(params[key]).map { "\(key.replacingOccurrences(of: "_", with: " ")) \($0)" }
        }
        guard !rest.isEmpty else { return nil }
        return "\(verb)" + (place.map { " \($0)" } ?? "") + " with " + rest.joined(separator: ", ")
    }

    private static func money(_ value: FeatureJSON?) -> String? {
        switch value {
        case .number(let number)?: String(format: "%.2f", number)
        case .string(let text)?: Double(text).map { String(format: "%.2f", $0) } ?? text
        default: nil
        }
    }

    private static func scalar(_ value: FeatureJSON?) -> String? {
        switch value {
        case .string(let text)?: text
        case .bool(let flag)?: String(flag)
        case .number(let number)?:
            number.rounded() == number ? String(Int(number)) : String(number)
        default: nil
        }
    }
}

private struct CrewOpenByDefault: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether crew delegation lines start expanded; set for offscreen snapshots.
    var crewOpenByDefault: Bool {
        get { self[CrewOpenByDefault.self] }
        set { self[CrewOpenByDefault.self] = newValue }
    }
}
