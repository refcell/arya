import AryaDesign
import SwiftUI

/// What a run is about, pinned above its thread so the pane is never empty: who or what started
/// it, its plan as a checklist that ticks while it runs, and what it read.
struct RunBrief: Hashable, Sendable {
    enum Mark: Hashable, Sendable { case done, current, next, skipped, blocked }

    struct Item: Hashable, Sendable {
        var mark: Mark
        var text: String
    }

    /// "Started by you", "Priya handed this off", "Started by its schedule".
    var trigger: String
    var plan: [Item]
    /// Where the checklist comes from: the run's own plan, or its steps so far.
    var planSource: String
    /// What the run read: "tracker.get ISSUE-7", in order, without repeats; shown next to the
    /// run's own plan (a checklist of steps already lists the calls).
    var reads: [String]

    /// Rows shown before "+N more".
    static let shownItems = 8

    /// `done` and `expected` are the run's facts (`stepIndex`, `estimatedSteps`), the same
    /// numbers as the header's "9 of ~9 steps".
    static func build(
        stream: RunStream, events: [FeatureEvent], done: Int? = nil, expected: Int?
    ) -> RunBrief {
        RunBrief(
            trigger: trigger(stream), plan: [], planSource: "",
            reads: reads(stream)
        )
        .with(
            plan: ownPlan(stream, events: events), done: done, expected: expected, stream: stream)
    }

    private func with(plan own: [Item]?, done: Int?, expected: Int?, stream: RunStream)
        -> RunBrief
    {
        var brief = self
        if let own, !own.isEmpty {
            brief.plan = own
            brief.planSource = "the run's plan"
        } else {
            brief.plan = RunBrief.steps(stream, done: done, expected: expected)
            brief.reads = []  // the checklist already lists every call
            brief.planSource = stream.status == .running ? "steps so far" : "steps"
        }
        return brief
    }

    static func trigger(_ stream: RunStream) -> String {
        let trigger =
            stream.steps.lazy.compactMap { step -> String? in
                if case .started(let trigger) = step.kind { return trigger }
                return nil
            }.first ?? "manual"
        switch trigger {
        case "manual": return "Started by you"
        case "schedule", "cron", "interval": return "Started by its schedule"
        case "join": return "Started when its crew finished"
        case "message":
            let words = RunInput.message(stream.input ?? "")
            if let range = words.range(of: " handed this to you") {
                return "\(words[..<range.lowerBound]) handed this off"
            }
            if let range = words.range(of: " asked:") {
                return "\(words[..<range.lowerBound]) asked"
            }
            return "Started by a message"
        default: return "Started by \(trigger.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// The plan the run recorded at its end (`plan.updated` from this run).
    static func ownPlan(_ stream: RunStream, events: [FeatureEvent]) -> [Item]? {
        guard
            let plan = events.last(where: { $0.type == "plan.updated" && $0.run == stream.run }),
            case .array(let items)? = plan.payload["items"]
        else { return nil }
        return items.compactMap { item in
            guard let text = item["text"]?.string else { return nil }
            let mark: Mark =
                switch item["status"]?.string {
                case "done": .done
                case "in_progress": .current
                case "skipped": .skipped
                case "blocked": .blocked
                default: .next
                }
            return Item(mark: mark, text: text)
        }
    }

    /// The run's work steps as a checklist: done, the one running, and while the run is live
    /// how many more its steward usually takes.
    static func steps(_ stream: RunStream, done: Int? = nil, expected: Int?) -> [Item] {
        var items = stream.steps.compactMap { step -> Item? in
            switch step.kind {
            case .toolCall(let call):
                let text = [call.tool, RunThreadText.argument(call.input)].compactMap { $0 }
                    .joined(separator: " ")
                return Item(mark: call.finished ? .done : .current, text: text)
            case .action(let action):
                let target = EntityName.plain(action.target)
                let mark: Mark = RunThreadText.failed(action) ? .blocked : .done
                return Item(mark: mark, text: RunTitle.verb(action.kind) + " " + target)
            case .delegated(let delegation):
                return Item(
                    mark: delegation.childStatus == .running ? .current : .done,
                    text: "hand off: " + delegation.title)
            case .message(let role, _) where role == "streaming":
                return Item(mark: .current, text: "write the reply")
            case .message:
                return Item(mark: .done, text: StreamStepText.title(step.kind))
            default: return nil
            }
        }
        if stream.status == .running {
            let done = done ?? RunThreadText.steps(stream.steps).count
            if let expected, expected > done {
                let more = expected - done
                items.append(
                    Item(mark: .next, text: "~\(more) more step\(more == 1 ? "" : "s") expected"))
            } else if !items.contains(where: { $0.mark == .current }) {
                items.append(Item(mark: .next, text: "next step"))
            }
        }
        return items
    }

    static func reads(_ stream: RunStream) -> [String] {
        var seen: [String] = []
        for step in stream.steps {
            guard case .toolCall(let call) = step.kind, call.tool != "shell" else { continue }
            let text = [call.tool, RunThreadText.argument(call.input)].compactMap { $0 }
                .joined(separator: " ")
            if !seen.contains(text) { seen.append(text) }
        }
        return seen
    }

    static func glyph(_ mark: Mark) -> String {
        switch mark {
        case .done: "✓"
        case .current: "●"
        case .next: "○"
        case .skipped: "–"
        case .blocked: "!"
        }
    }
}

/// The brief as a compact block: trigger and input, the checklist, what it read.
struct RunBriefView: View {
    var brief: RunBrief
    var reading: RunInput?
    var openRun: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text(brief.trigger.uppercased()).aryaText(AryaFont.label, AryaColor.inkFaint)
            if let reading { RunInputView(reading: reading, openRun: openRun) }
            if !brief.plan.isEmpty {
                HStack(spacing: AryaSpace.s1) {
                    Text("PLAN").aryaText(AryaFont.label, AryaColor.inkFaint)
                    Text("· \(brief.planSource)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                .padding(.top, AryaSpace.s1)
                VStack(alignment: .leading, spacing: AryaSpace.s1 / 2) {
                    ForEach(
                        Array(brief.plan.prefix(RunBrief.shownItems).enumerated()), id: \.offset
                    ) {
                        _, item in
                        row(item)
                    }
                    if brief.plan.count > RunBrief.shownItems {
                        Text("+\(brief.plan.count - RunBrief.shownItems) more")
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    }
                }
            }
            if !brief.reads.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text("READ").aryaText(AryaFont.label, AryaColor.inkFaint)
                    Text(brief.reads.joined(separator: " · "))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        .lineLimit(2).truncationMode(.tail)
                }
                .padding(.top, AryaSpace.s1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func row(_ item: RunBrief.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(RunBrief.glyph(item.mark)).aryaText(AryaFont.mono, color(item.mark))
                .accessibilityHidden(true)
            Text(item.text).aryaText(
                AryaFont.mono, item.mark == .next ? AryaColor.inkFaint : AryaColor.ink
            )
            .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(RunBrief.spoken(item.mark)): \(item.text)")
    }

    private func color(_ mark: RunBrief.Mark) -> Color {
        switch mark {
        case .done: AryaColor.positive
        case .current: AryaColor.ink
        case .next, .skipped: AryaColor.inkFaint
        case .blocked: AryaColor.negative
        }
    }
}

extension RunBrief {
    static func spoken(_ mark: Mark) -> String {
        switch mark {
        case .done: "done"
        case .current: "in progress"
        case .next: "next"
        case .skipped: "skipped"
        case .blocked: "blocked"
        }
    }
}
