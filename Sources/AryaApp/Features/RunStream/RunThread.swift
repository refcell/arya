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
    /// The split work pane shows the header above both halves instead.
    var showsHeader = true
    /// False where the run brief above the thread already shows the input.
    var showsInput = true
    /// The selected work step, shared with the work pane; nil outside the split view.
    var selection: Binding<String?>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            if showsHeader { RunHeader(stream: stream, accessory: accessory) }
            if let store = context.store { FeatureWriteErrorLine(store: store) }
            if showsInput, let reading = stream.reading {
                RunInputView(reading: reading, openRun: context.openRun)
            }
            LazyVStack(alignment: .leading, spacing: AryaSpace.s1) {
                ForEach(RunThreadText.visible(stream.steps)) { step in
                    if case .action(let action) = step.kind,
                        case .awaitingApproval(let approval) = action.outcome
                    {
                        InlineApproval(
                            action: action, approval: approval, source: stream.input,
                            texts: context.store?.approvalTexts[approval],
                            // ↩ belongs to the composer; approve by click or in Needs you.
                            primary: false,
                            decide: context.decide
                        )
                        .padding(.vertical, AryaSpace.s3)
                    } else {
                        ThreadLine(
                            step: step, now: now,
                            selected: selection?.wrappedValue == step.id,
                            select: selectAction(step))
                    }
                }
            }
        }
    }

    private func selectAction(_ step: StreamStep) -> (() -> Void)? {
        guard let selection, RunWork.isWork(step.kind) else { return nil }
        return { selection.wrappedValue = step.id }
    }
}

/// Trigger and start time, then the run's facts in mono, with the run controls at the right.
struct RunHeader: View {
    var stream: RunStream
    var accessory = AnyView(EmptyView())
    var now = Date()
    /// The workspace's numbers; when set they replace the projection's counts and progress.
    var facts: FeatureRunFacts? = nil

    private var metrics: RunMetrics {
        var metrics = stream.facts
        guard let facts else {
            if let progress = stream.progress, case .running = stream.status {
                metrics.elapsed = FeatureRunFacts.elapsedText(
                    now.timeIntervalSince(progress.started), running: true)
            }
            return metrics
        }
        metrics.seconds = facts.running ? nil : facts.elapsedSeconds
        metrics.elapsed = facts.elapsedText(now: now)
        metrics.decisions = facts.decisions
        metrics.actions = facts.actionsProposed
        return metrics
    }

    private var progress: RunProgress? {
        guard let facts else { return stream.progress }
        guard facts.running else { return nil }
        return RunProgress(
            done: facts.stepIndex, expected: facts.estimatedSteps, started: facts.started)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .center, spacing: AryaSpace.s2) {
                if case .running = stream.status { StatusDot(.running) }
                Text(RunThreadText.meta(stream)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                Spacer(minLength: AryaSpace.s3)
                accessory
            }
            Text(metrics.text).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let progress {
                HStack(spacing: AryaSpace.s2) {
                    AryaSpinner()
                    Text(progress.text(now: now)).aryaText(AryaFont.monoSmall, AryaColor.ink)
                        .fixedSize()
                    AryaProgressBar(progress.fraction)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Running: \(progress.text(now: now))")
            }
        }
    }
}

/// One step as one quiet line: time, then text. Tool calls and actions are mono with a mark
/// and expand on click.
private struct ThreadLine: View {
    var step: StreamStep
    var now: Date
    var selected = false
    /// Set in the split view: a click selects the step's block in the work pane instead of
    /// expanding it here.
    var select: (() -> Void)? = nil
    @AryaState private var toggled = false
    @Environment(\.crewOpenByDefault) private var crewOpen

    /// Tool calls start open, so their output reads inline (folded after four lines); crew
    /// lines can start open (offscreen snapshots). A click flips either default.
    private var open: Bool {
        if select != nil { return false }
        switch step.kind {
        // A running call shows its output as it streams; a finished one folds to its line.
        case .toolCall(let call) where !call.finished: return !toggled
        case .delegated where crewOpen: return !toggled
        default: return toggled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                // Only steps carry a time; notes (decisions, the run's end) align under them.
                Text(StreamStepText.clock(step.at))
                    .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    .help(FeatureTime.absolute(step.at))
                    .opacity(RunThreadText.isStep(step.kind) ? 1 : 0)
                line
                Spacer(minLength: 0)
            }
            .padding(.vertical, AryaSpace.s1 / 2)
            .background(selected ? AryaColor.selection : .clear)
            .contentShape(Rectangle())
            .onTapGesture {
                if let select {
                    select()
                } else if expandable {
                    toggled.toggle()
                }
            }
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
            let argument = RunThreadText.argument(call.input)
            Text(HumanText.tool(call.tool) + (argument == nil ? "" : ":"))
                .aryaText(AryaFont.mono, AryaColor.ink)
                .lineLimit(1).fixedSize()
                .help(call.tool)
            if let argument {
                Text(RunThreadText.shown(argument)).aryaText(AryaFont.mono, AryaColor.inkMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(argument)
            }
            if let output = call.output, let result = RunThreadText.arrow(output) {
                Text("→ \(RunThreadText.shown(result))")
                    .aryaText(AryaFont.mono, AryaColor.inkMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Text(RunThreadText.toolMeta(call, elapsed: now.timeIntervalSince(step.at)))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        case .action(let action):
            MarkGlyph(mark: StreamStepText.mark(step.kind))
            let refused = RunThreadText.failed(action)
            Text(HumanText.stepVerb(action.kind))
                .aryaText(AryaFont.mono, refused ? AryaColor.negative : AryaColor.ink)
                .help(action.kind)
            if !action.target.isEmpty {
                EntityLabel(ref: action.target, color: refused ? AryaColor.negative : AryaColor.ink)
            }
            if let result = RunThreadText.arrow(action.params).map(EntityName.humanize) {
                Text("→ \(RunThreadText.shown(result))")
                    .aryaText(AryaFont.mono, AryaColor.inkMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let note = RunThreadText.actionNote(action) {
                Text(note).aryaText(
                    AryaFont.monoSmall,
                    RunThreadText.failed(action) ? AryaColor.negative : AryaColor.inkFaint)
            }
            if let check = action.check {
                Text(check.text(since: step.at)).aryaText(
                    AryaFont.monoSmall,
                    check.status == "resolved"
                        ? AryaColor.positive
                        : check.status == "reopened" ? AryaColor.negative : AryaColor.inkFaint
                )
                .help(check.note ?? "")
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
        case .message(let role, _):
            Text(StreamStepText.title(step.kind)).aryaText(AryaFont.body, AryaColor.ink)
                .textSelection(.enabled)
            if role == "streaming" { BlinkingCaret() }
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
        case .running: AryaSpinner().accessibilityLabel("running")
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
    /// Needs you shows the keys on the buttons (A approve, D deny, C correct).
    var showsKeys = false
    /// Opens the run to correct it; Needs you passes it.
    var correct: (() -> Void)? = nil

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
                        Text(HumanText.change(change, kind: action.kind, params: action.params))
                            .aryaText(AryaFont.mono, AryaColor.ink)
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
                if let refusal = action.refusal {
                    Text("Refused: \(refusal)").aryaText(AryaFont.caption, AryaColor.negative)
                }
                // One row when it fits; otherwise Approve gets its own line under the others.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AryaSpace.s2) {
                        Spacer()
                        correctButton
                        deny
                        approve
                    }
                    VStack(alignment: .trailing, spacing: AryaSpace.s2) {
                        HStack(spacing: AryaSpace.s2) {
                            Spacer()
                            correctButton
                            deny
                        }
                        approve
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval: \(RunThreadText.approvalTitle(action))")
    }

    @ViewBuilder private var correctButton: some View {
        if let correct {
            Button("Correct", action: correct)
                .buttonStyle(AryaSecondaryButtonStyle(keys: showsKeys ? "C" : nil))
                .help("Open the run to correct its decision")
        }
    }

    @ViewBuilder private var deny: some View {
        // Esc closes things; it never denies. Needs you denies on D.
        Button("Deny") { decide(.deny(approval: approval, reason: "")) }
            .buttonStyle(AryaSecondaryButtonStyle(keys: showsKeys ? "D" : nil))
    }

    @ViewBuilder private var approve: some View {
        let button = Button(RunThreadText.approveLabel(action)) {
            decide(.approve(approval: approval))
        }
        .buttonStyle(AryaPrimaryButtonStyle(keys: showsKeys ? "A" : nil))
        if primary { button.keyboardShortcut(.defaultAction) } else { button }
    }
}

/// Text for the run thread, kept apart from layout so it can be tested.
enum RunThreadText {
    /// Steps worth a line: the start is the header, so it is left out; the finish stays as
    /// the one place the summary appears.
    /// One step (decision 0067 wording, app side): a row the person sees in the thread with
    /// its time: each tool call, each action (approval asks included), each message, each
    /// hand-off. Decisions, thinking, status and the run's end are notes on those rows, not
    /// steps. Progress, the brief and the usual count all count these; workspace's
    /// `visibleSteps` uses the same rule.
    static func isStep(_ kind: StreamStep.Kind) -> Bool {
        switch kind {
        case .toolCall, .action, .message, .delegated: true
        default: false
        }
    }

    /// The run's steps, in order.
    static func steps(_ steps: [StreamStep]) -> [StreamStep] { steps.filter { isStep($0.kind) } }

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
        case "join": "checks delegated work"
        default: "started by \(trigger)"
        }
    }

    static func meta(_ stream: RunStream, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let parent = stream.reading?.parent {
            parts.append("checks the delegated work from \(parent.title)")
        } else if case .started(let trigger) = stream.steps.first?.kind {
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

    /// "via tracker · live · 1.2 s", or "via shell · running… 3 s" with the time so far.
    /// An argument or result as the thread shows it: whole when short, else cut at a word end
    /// with a trailing ellipsis (never mid-word; it may wrap to a second line).
    static let shownLimit = 72

    static func shown(_ text: String) -> String { HumanText.clip(text, max: shownLimit) }

    static func toolMeta(_ call: ToolCallStep, elapsed: Double? = nil) -> String {
        var parts = [
            call.binding.map { "via \(EntityName.plain($0))" },
            call.source.map(StreamStepText.sourceWord),
        ]
        if !call.finished {
            let counter = elapsed.map { FeatureRunFacts.elapsedText(max(0, $0), running: true) }
            parts.append(counter.map { "running… \($0)" } ?? "running")
        }
        if let seconds = call.durationSeconds { parts.append(FeatureTime.duration(seconds)) }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    static func failed(_ action: ProposedActionStep) -> Bool {
        if action.refusal != nil, !isAwaiting(action) { return true }
        switch action.outcome {
        case .failed, .rejected, .denied: return true
        default: return false
        }
    }

    /// A short note after an action's line; nil when the mark says it all (it ran).
    static func isAwaiting(_ action: ProposedActionStep) -> Bool {
        if case .awaitingApproval = action.outcome { return true }
        return false
    }

    static func actionNote(_ action: ProposedActionStep) -> String? {
        if let refusal = action.refusal, !isAwaiting(action) { return "refused: \(refusal)" }
        switch action.outcome {
        case .executed: return action.dryRun ? ActionWords.done(action) : nil
        case .proposed, .awaitingApproval: return nil
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
        HumanText.approveLabel(kind: action.kind, params: action.params)
    }

    /// "Reply to inbox:MSG-201".
    static func approvalTitle(_ action: ProposedActionStep) -> String {
        let verb = action.kind.prefix(1).uppercased() + action.kind.dropFirst()
        let target = EntityName.plain(action.target)
        return action.target.isEmpty ? verb : "\(verb) \(preposition(action.kind)) \(target)"
    }

    /// "via inbox · risk medium"; why it was held is the workspace's sentence.
    static func approvalMeta(_ action: ProposedActionStep) -> String {
        var parts: [String] = []
        if let binding = action.binding { parts.append("via \(EntityName.plain(binding))") }
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
    /// Keys that read as a phrase after the target: "to person:alex", "into billing".
    private static let prepositions: Set<String> = ["to", "from", "into", "onto", "for", "as"]

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
            return EntityName.humanize(
                "\(verb) \(amount)\(currency)" + (place.map { " on \($0)" } ?? ""))
        }
        let used = Set(referenceKeys + ["currency"]).union(contentKeys)
        var phrases: [String] = []
        var rest: [String] = []
        for key in params.keys.sorted() where !used.contains(key) {
            guard let value = scalar(params[key]) else { continue }
            if key == action.kind {
                phrases.append("as \(value)")
            } else if prepositions.contains(key) {
                phrases.append("\(key) \(value)")
            } else if key == "queue" {
                phrases.append("to \(value)")
            } else {
                rest.append("\(key.replacingOccurrences(of: "_", with: " ")) \(value)")
            }
        }
        guard !phrases.isEmpty || !rest.isEmpty else { return nil }
        var sentence = verb + (place.map { " \($0)" } ?? "")
        if !phrases.isEmpty { sentence += " " + phrases.joined(separator: " ") }
        if !rest.isEmpty { sentence += " with " + rest.joined(separator: ", ") }
        return EntityName.humanize(sentence)
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

private struct InitialWorkTab: EnvironmentKey {
    static let defaultValue: WorkTab? = nil
}

extension EnvironmentValues {
    /// The work tab a run opens on when nothing was picked; set for offscreen snapshots.
    var initialWorkTab: WorkTab? {
        get { self[InitialWorkTab.self] }
        set { self[InitialWorkTab.self] = newValue }
    }

    /// Whether crew delegation lines start expanded; set for offscreen snapshots.
    var crewOpenByDefault: Bool {
        get { self[CrewOpenByDefault.self] }
        set { self[CrewOpenByDefault.self] = newValue }
    }
}

/// The run's input in plain words, with any raw text collapsed behind "Show raw".
struct RunInputView: View {
    var reading: RunInput
    var openRun: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(label).aryaText(AryaFont.overline, AryaColor.inkFaint)
            switch reading.body {
            case .text(let text):
                Text(text).aryaText(AryaFont.prose, AryaColor.inkMuted).textSelection(.enabled)
            case .structured(let summary):
                Text(summary).aryaText(AryaFont.prose, AryaColor.inkMuted)
            case .crew(let children):
                ForEach(children, id: \.self) { child in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(child.sentence).aryaText(AryaFont.prose, AryaColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let run = child.run, let openRun {
                            Button("Open child run · \(child.title)") { openRun(run) }
                                .buttonStyle(.aryaTertiary)
                                .help("Open the child run's thread")
                        }
                    }
                }
            }
            if let raw = reading.raw {
                DisclosureGroup {
                    MachineText(raw)
                } label: {
                    Text("Show raw").aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
            }
        }
    }

    private var label: String {
        if case .crew = reading.body { return "From the crew" }
        return "Input"
    }
}
