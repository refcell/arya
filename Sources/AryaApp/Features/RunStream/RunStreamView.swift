import AryaDesign
import SwiftUI

/// The run stream: one run's steps in order, updating live while the run is in progress.
struct RunStreamView: View {
    @ObservedObject var store: FeatureStore
    var run: String

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading the run.", guidance: "Reading the ledger.")
        case .failed(let message):
            EmptyState(
                "The run could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            content(RunStream.build(events: events, run: run))
        }
    }

    @ViewBuilder
    private func content(_ stream: RunStream) -> some View {
        if stream.steps.isEmpty {
            EmptyState(
                "No steps yet.",
                guidance: "Steps appear here as the run reads, decides, and proposes.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AryaSpace.s4) {
                    StatusLine(status: stream.status)
                    FeatureWriteErrorLine(store: store)
                    ForEach(stream.steps) { step in
                        StreamStepRow(step: step, now: store.now, context: context(stream))
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
                .padding(AryaSpace.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AryaColor.canvas)
        }
    }

    private func context(_ stream: RunStream) -> StepContext {
        StepContext(steward: stream.steward, run: stream.run) { write in
            Task { await store.perform(write) }
        }
    }
}

/// What a step needs beyond its own data: where it lives and how to record a decision.
struct StepContext {
    var steward: String?
    var run: String
    var decide: (FeatureWrite) -> Void
}

extension RunStatus {
    /// The design-system status shown as a dot and a word.
    var aryaStatus: AryaStatus {
        switch self {
        case .running: return .running
        case .finished: return .done
        case .failed: return .failed
        }
    }
}

private struct StatusLine: View {
    var status: RunStatus

    var body: some View {
        HStack(spacing: AryaSpace.s2) {
            StatusBadge(status.aryaStatus)
            if case .finished(_, let summary) = status, !summary.isEmpty {
                Text(summary).aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One step: gutter number, title, time, and an optional body.
struct StreamStepRow: View {
    var step: StreamStep
    var now: Date
    var context: StepContext

    var body: some View {
        StepRow(
            sequence: step.number, time: FeatureTime.relative(step.at, now: now),
            absoluteTime: FeatureTime.absolute(step.at),
            isRunning: StreamStepText.isRunning(step.kind)
        ) {
            StepTitle(kind: step.kind)
        } detail: {
            StepBody(step: step, now: now, context: context)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StreamStepText.spoken(step, now: now))
    }
}

/// Titles and spoken labels for steps, kept apart from layout so they can be tested.
enum StreamStepText {
    /// The short label before a step's title (`tool`, `Decision`), or nil.
    static func label(_ kind: StreamStep.Kind) -> String? {
        switch kind {
        case .toolCall: return "tool"
        case .decision: return "Decision"
        case .action: return "action"
        case .thinking: return "thinking"
        default: return nil
        }
    }

    /// The step's title.
    static func title(_ kind: StreamStep.Kind) -> String {
        switch kind {
        case .started(let trigger): return "Started by \(trigger) trigger"
        case .message(let role, let text): return role == "user" ? "You: \(text)" : text
        case .thinking(let text): return text
        case .status(let state, let detail): return detail.isEmpty ? state : detail
        case .error(let message): return "Error: \(message)"
        case .toolCall(let call): return call.tool
        case .decision(_, let choice, _, _): return choice
        case .action(let action): return "\(action.kind) \(action.target)"
        case .finished(let status, let summary): return summary.isEmpty ? status : summary
        case .failed(let reason): return "Run failed: \(reason)"
        }
    }

    /// The caption describing an action's outcome.
    static func outcome(_ outcome: ActionOutcome) -> String {
        switch outcome {
        case .proposed: return "Proposed"
        case .awaitingApproval: return "Waiting for approval"
        case .approved: return "Approved, running"
        case .executed: return "Ran"
        case .failed(let error): return "failed: \(error)"
        case .rejected(let rule): return "Blocked by \(rule)"
        case .denied(_, let reason): return reason.isEmpty ? "Denied" : "Denied: \(reason)"
        }
    }

    /// The approval card data for an action waiting in this stream.
    static func approval(
        _ action: ProposedActionStep, _ approval: String, step: StreamStep, context: StepContext
    ) -> ApprovalItem {
        ApprovalItem(
            id: approval, actionID: action.actionID, kind: action.kind, target: action.target,
            summary: action.summary, rationale: action.rationale, steward: context.steward,
            run: context.run, requestedAt: step.at)
    }

    /// Whether the step is still in progress: a tool call without its result.
    static func isRunning(_ kind: StreamStep.Kind) -> Bool {
        if case .toolCall(let call) = kind { return call.output == nil }
        return false
    }

    /// "ok · 1.2 s", "failed · 850 ms", or "running" for a tool call.
    static func toolCaption(_ call: ToolCallStep) -> String {
        guard call.output != nil else { return "running" }
        let status = call.isError ? "failed" : "ok"
        guard let seconds = call.durationSeconds else { return status }
        return "\(status) · \(FeatureTime.duration(seconds))"
    }

    /// The VoiceOver label: "Step 4, decision, bug, 2m ago".
    static func spoken(_ step: StreamStep, now: Date) -> String {
        let parts = [
            "Step \(step.number)", label(step.kind)?.lowercased(), title(step.kind),
            FeatureTime.relative(step.at, now: now),
        ]
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

private struct StepTitle: View {
    var kind: StreamStep.Kind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            if let label = StreamStepText.label(kind) {
                Text(label).aryaText(AryaFont.caption, AryaColor.inkFaint)
            }
            title
        }
    }

    @ViewBuilder private var title: some View {
        let text = StreamStepText.title(kind)
        switch kind {
        case .toolCall, .action: Text(text).aryaText(AryaFont.mono, AryaColor.ink)
        case .decision: Text(text).aryaText(AryaFont.heading, AryaColor.ink)
        case .error, .failed: Text(text).aryaText(AryaFont.bodyStrong, AryaColor.negative)
        case .thinking, .status: Text(text).aryaText(AryaFont.body, AryaColor.inkMuted)
        default: Text(text).aryaText(AryaFont.bodyStrong, AryaColor.ink)
        }
    }
}

private struct StepBody: View {
    var step: StreamStep
    var now: Date
    var context: StepContext

    var body: some View {
        switch step.kind {
        case .toolCall(let call): ToolCallBody(call: call)
        case .decision(let id, _, let rationale, let alternatives):
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                muted(rationale)
                if !alternatives.isEmpty {
                    muted("Also considered: " + alternatives.joined(separator: ", "))
                }
                Text(id).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
        case .action(let action):
            if case .awaitingApproval(let approval) = action.outcome {
                ApprovalItemCard(
                    item: StreamStepText.approval(action, approval, step: step, context: context),
                    now: now, decide: context.decide)
            } else {
                actionBody(action)
            }
        default: EmptyView()
        }
    }

    private func actionBody(_ action: ProposedActionStep) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(spacing: AryaSpace.s2) {
                muted(action.rationale)
                Spacer(minLength: AryaSpace.s2)
                if let policy = AryaPolicy(rawValue: action.policy) { PolicyChip(policy) }
            }
            Text(StreamStepText.outcome(action.outcome))
                .aryaText(AryaFont.caption, outcomeColor(action.outcome))
        }
    }

    private func muted(_ text: String) -> some View {
        Text(text).aryaText(AryaFont.body, AryaColor.inkMuted).lineLimit(3)
    }

    private func outcomeColor(_ outcome: ActionOutcome) -> Color {
        switch outcome {
        case .executed: return AryaColor.positive
        case .failed, .rejected, .denied: return AryaColor.negative
        default: return AryaColor.inkFaint
        }
    }
}

private struct ToolCallBody: View {
    var call: ToolCallStep

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: AryaSpace.s2) {
                CodeBlock(call.input.compactText)
                if let output = call.output { CodeBlock(output.compactText) }
            }
        } label: {
            Text(StreamStepText.toolCaption(call))
                .aryaText(AryaFont.caption, call.isError ? AryaColor.negative : AryaColor.inkFaint)
        }
    }
}
