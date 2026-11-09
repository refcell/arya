import AryaDesign
import SwiftUI

/// The run stream: one run's steps in order, updating live while the run is in progress.
struct RunStreamView: View {
    @ObservedObject var store: FeatureStore
    var run: String

    var body: some View {
        switch store.state {
        case .loading:
            FeatureEmptyState(title: "Loading the run.", guidance: "Reading the ledger.")
        case .failed(let message):
            FeatureEmptyState(
                title: "The run could not be loaded.", guidance: message,
                actionTitle: "Retry", action: { Task { await store.reload() } })
        case .loaded(let events):
            content(RunStream.build(events: events, run: run))
        }
    }

    @ViewBuilder
    private func content(_ stream: RunStream) -> some View {
        if stream.steps.isEmpty {
            FeatureEmptyState(
                title: "No steps yet.",
                guidance: "Steps appear here as the run reads, decides, and proposes.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AryaSpace.s4) {
                    RunStatusLine(status: stream.status)
                    ForEach(stream.steps) { step in
                        StreamStepRow(step: step, now: store.now)
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
}

/// The run's status as a dot and a word.
struct RunStatusLine: View {
    var status: RunStatus

    var body: some View {
        HStack(spacing: AryaSpace.s2) {
            FeatureDot(color: color)
            Text(status.word).aryaText(AryaFont.caption).foregroundStyle(AryaColor.inkMuted)
            if case .finished(_, let summary) = status, !summary.isEmpty {
                Text(summary).aryaText(AryaFont.caption).foregroundStyle(AryaColor.inkFaint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch status {
        case .running: return AryaColor.accent
        case .finished: return AryaColor.positive
        case .failed: return AryaColor.negative
        }
    }
}

/// One step: gutter number, title, time, and an optional body.
struct StreamStepRow: View {
    var step: StreamStep
    var now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(String(format: "%02d", step.number))
                .aryaText(AryaFont.monoSmall)
                .foregroundStyle(AryaColor.inkFaint)
                .frame(width: AryaSize.stepGutter, alignment: .leading)
            VStack(alignment: .leading, spacing: AryaSpace.s2) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    StepTitle(kind: step.kind)
                    Spacer(minLength: AryaSpace.s3)
                    Text(FeatureTime.relative(step.at, now: now))
                        .aryaText(AryaFont.caption)
                        .foregroundStyle(AryaColor.inkFaint)
                        .help(FeatureTime.absolute(step.at))
                }
                StepBody(kind: step.kind)
            }
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
                Text(label).aryaText(AryaFont.caption).foregroundStyle(AryaColor.inkFaint)
            }
            title
        }
    }

    @ViewBuilder private var title: some View {
        let text = StreamStepText.title(kind)
        switch kind {
        case .toolCall, .action: Text(text).aryaText(AryaFont.mono).foregroundStyle(AryaColor.ink)
        case .decision: Text(text).aryaText(AryaFont.heading).foregroundStyle(AryaColor.ink)
        case .error, .failed:
            Text(text).aryaText(AryaFont.bodyStrong).foregroundStyle(AryaColor.negative)
        case .thinking, .status:
            Text(text).aryaText(AryaFont.body).foregroundStyle(AryaColor.inkMuted)
        default: Text(text).aryaText(AryaFont.bodyStrong).foregroundStyle(AryaColor.ink)
        }
    }
}

private struct StepBody: View {
    var kind: StreamStep.Kind

    var body: some View {
        switch kind {
        case .toolCall(let call): ToolCallBody(call: call)
        case .decision(let id, _, let rationale, let alternatives):
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                muted(rationale)
                if !alternatives.isEmpty {
                    muted("Also considered: " + alternatives.joined(separator: ", "))
                }
                Text(id).aryaText(AryaFont.monoSmall).foregroundStyle(AryaColor.inkFaint)
            }
        case .action(let action):
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack(spacing: AryaSpace.s2) {
                    muted(action.rationale)
                    Spacer(minLength: AryaSpace.s2)
                    PolicyChip(policy: action.policy)
                }
                Text(StreamStepText.outcome(action.outcome))
                    .aryaText(AryaFont.caption)
                    .foregroundStyle(outcomeColor(action.outcome))
            }
        default: EmptyView()
        }
    }

    private func muted(_ text: String) -> some View {
        Text(text).aryaText(AryaFont.body).foregroundStyle(AryaColor.inkMuted).lineLimit(3)
    }

    private func outcomeColor(_ outcome: ActionOutcome) -> Color {
        switch outcome {
        case .executed: return AryaColor.positive
        case .failed, .rejected, .denied: return AryaColor.negative
        case .awaitingApproval: return AryaColor.accent
        default: return AryaColor.inkFaint
        }
    }
}

private struct ToolCallBody: View {
    var call: ToolCallStep

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: AryaSpace.s2) {
                    FeatureCodeBlock(text: call.input.compactText)
                    if let output = call.output { FeatureCodeBlock(text: output.compactText) }
                }
            } label: {
                Text(caption).aryaText(AryaFont.caption)
                    .foregroundStyle(call.isError ? AryaColor.negative : AryaColor.inkFaint)
            }
        }
    }

    private var caption: String {
        guard call.output != nil else { return "running" }
        let status = call.isError ? "failed" : "ok"
        guard let seconds = call.durationSeconds else { return status }
        return "\(status) · \(FeatureTime.duration(seconds))"
    }
}
