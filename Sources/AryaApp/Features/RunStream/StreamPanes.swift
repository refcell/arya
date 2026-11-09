import AryaDesign
import SwiftUI

/// The left pane: conversation, reasoning, status, and decisions as compact timed rows.
struct ConversationPane: View {
    var steps: [StreamStep]
    var now: Date

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                ConversationRow(step: step, now: now).transition(.opacity)
            }
        }
    }
}

private struct ConversationRow: View {
    var step: StreamStep
    var now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(StreamStepText.clock(step.at))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                .help(FeatureTime.absolute(step.at))
            Text(StreamStepText.tag(step.kind))
                .aryaText(AryaFont.overline, tagColor)
                .frame(width: AryaSize.stepGutter * 2, alignment: .leading)
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text(StreamStepText.title(step.kind)).aryaText(titleStyle, titleColor)
                    .textSelection(.enabled)
                if case .decision(_, _, let rationale, let alternatives) = step.kind {
                    Text(rationale).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    if !alternatives.isEmpty {
                        Text("also considered: " + alternatives.joined(separator: ", "))
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    }
                }
            }
        }
        .padding(.vertical, AryaSpace.s1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StreamStepText.spoken(step, now: now))
    }

    private var titleStyle: AryaTextStyle {
        switch step.kind {
        case .decision: return AryaFont.bodyStrong
        case .thinking, .status: return AryaFont.caption
        default: return AryaFont.body
        }
    }

    private var titleColor: Color {
        switch step.kind {
        case .error, .failed: return AryaColor.negative
        case .thinking, .status, .started: return AryaColor.inkMuted
        default: return AryaColor.ink
        }
    }

    private var tagColor: Color {
        switch step.kind {
        case .error, .failed: return AryaColor.negative
        case .finished: return AryaColor.positive
        default: return AryaColor.inkFaint
        }
    }
}

/// The right pane: pending approvals pinned first, then tool calls and actions as cards.
struct WorkPane: View {
    var stream: RunStream
    var now: Date
    var context: StepContext

    var body: some View {
        LazyVStack(alignment: .leading, spacing: AryaSpace.s2) {
            if !stream.waiting.isEmpty {
                Text("Waiting for you").aryaText(AryaFont.overline, AryaColor.accent)
                ForEach(stream.waiting) { step in
                    if case .action(let action) = step.kind, let approval = step.pendingApproval {
                        ApprovalItemCard(
                            item: StreamStepText.approval(
                                action, approval, step: step, context: context),
                            now: now, decide: context.decide, store: context.store)
                    }
                }
            }
            if stream.work.isEmpty && stream.waiting.isEmpty {
                Text("No tool calls or actions yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
            } else if !stream.work.isEmpty {
                Text("Tools and actions").aryaText(AryaFont.overline, AryaColor.inkFaint)
                ForEach(stream.work) { step in
                    WorkCard(step: step, now: now).transition(.opacity)
                }
            }
        }
    }
}

/// One tool call or action: a mark, the mono command, its metadata, and collapsible detail.
private struct WorkCard: View {
    var step: StreamStep
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                WorkMarkView(mark: StreamStepText.mark(step.kind))
                Text(StreamStepText.title(step.kind))
                    .aryaText(AryaFont.mono, AryaColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AryaSpace.s2)
                if case .action(let action) = step.kind,
                    let policy = AryaPolicy(rawValue: action.policy)
                {
                    PolicyChip(policy)
                }
                Text(StreamStepText.clock(step.at)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            detail
        }
        .padding(AryaSpace.s2)
        .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: AryaRadius.medium).strokeBorder(
                AryaColor.rule, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(StreamStepText.spoken(step, now: now))
    }

    @ViewBuilder private var detail: some View {
        switch step.kind {
        case .toolCall(let call): ToolCallBody(call: call)
        case .action(let action):
            if !action.rationale.isEmpty {
                Text(action.rationale).aryaText(AryaFont.caption, AryaColor.inkMuted).lineLimit(3)
            }
            Text(StreamStepText.actionCaption(action)).aryaText(
                AryaFont.monoSmall, outcomeColor(action.outcome))
            if let run = action.routine { RoutineRunBody(run: run) }
        default: EmptyView()
        }
    }

    private func outcomeColor(_ outcome: ActionOutcome) -> Color {
        switch outcome {
        case .executed: return AryaColor.positive
        case .failed, .rejected, .denied: return AryaColor.negative
        default: return AryaColor.inkFaint
        }
    }
}

/// A check, cross, spinner dot, or hold mark for a work card.
private struct WorkMarkView: View {
    var mark: WorkMark

    var body: some View {
        switch mark {
        case .ok:
            Image(systemName: "checkmark").aryaText(AryaFont.caption, AryaColor.positive)
                .accessibilityLabel("done")
        case .failed:
            Image(systemName: "xmark").aryaText(AryaFont.caption, AryaColor.negative)
                .accessibilityLabel("failed")
        case .running: StatusDot(.running)
        case .waiting: StatusDot(.waiting)
        case .idle:
            Image(systemName: "circle").aryaText(AryaFont.caption, AryaColor.inkFaint)
                .accessibilityLabel("proposed")
        }
    }
}

/// The compact status of a work card.
enum WorkMark: Hashable, Sendable {
    case ok, failed, running, waiting, idle
}

extension StreamStepText {
    /// "14:02:07", the step's wall-clock time in the given zone.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// The short uppercase tag of a conversation row ("decide", "think", "agent").
    static func tag(_ kind: StreamStep.Kind) -> String {
        switch kind {
        case .started: return "start"
        case .message(let role, _): return role == "user" ? "you" : "agent"
        case .thinking: return "think"
        case .status: return "status"
        case .error: return "error"
        case .decision: return "decide"
        case .finished: return "done"
        case .failed: return "failed"
        case .toolCall: return "tool"
        case .action: return "action"
        }
    }

    /// The mark for a work card: tool calls by result, actions by outcome.
    static func mark(_ kind: StreamStep.Kind) -> WorkMark {
        switch kind {
        case .toolCall(let call):
            guard call.output != nil else { return .running }
            return call.isError ? .failed : .ok
        case .action(let action):
            switch action.outcome {
            case .executed: return .ok
            case .failed, .rejected, .denied: return .failed
            case .awaitingApproval: return .waiting
            case .approved: return .running
            case .proposed: return .idle
            }
        default: return .idle
        }
    }
}
