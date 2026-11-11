import AryaDesign
import Foundation
import SwiftUI

/// What the run inspector adds to the thread beside it (it never repeats the steps): what the
/// run used, the systems it touched, the policy behind each action, how each action held up
/// on its follow-up check, and other runs on the same things.
struct RunContext: Equatable {
    /// "2.1k tokens · $0.0042", nil when the run reported neither.
    var usage: String?
    /// "Search the inbox · MSG-140, MSG-201", one per system, busiest first.
    var systems: [String]
    /// One line per action: what, and the policy that let it run or asked a person.
    var policy: [Line]
    /// One line per checked action: what, and how it held up.
    var checks: [Line]
    /// Other runs that acted on the same targets, newest first.
    var related: [String]

    struct Line: Equatable, Identifiable {
        var id: String
        var what: String
        var how: String
        var tone: Tone
    }

    enum Tone: Equatable { case plain, asked, good, bad }

    static let relatedLimit = 5

    static func build(events: [FeatureEvent], run: String) -> RunContext {
        let stream = RunStream.build(events: events, run: run)
        var calls: [String: Int] = [:]
        var words: [String: [String]] = [:]
        var targets: [String: [String]] = [:]
        var policy: [Line] = []
        var checks: [Line] = []
        for step in stream.steps {
            switch step.kind {
            case .toolCall(let call):
                let system =
                    call.binding ?? call.tool.split(separator: ".").first.map(String.init)
                    ?? call.tool
                calls[system, default: 0] += 1
                // People's words for the tool ("Search the inbox"); raw names stay in TOOLS.
                let said = HumanText.tool(call.tool)
                if words[system]?.contains(said) != true { words[system, default: []].append(said) }
            case .action(let action):
                let what =
                    action.kind == "question"
                    ? action.summary
                    : ActionWords.sentence(kind: action.kind, target: action.target)
                if let system = action.binding, !action.target.isEmpty {
                    let name = EntityName.plain(action.target)
                    if targets[system]?.contains(name) != true {
                        targets[system, default: []].append(name)
                    }
                    calls[system, default: 0] += 0
                }
                policy.append(
                    Line(
                        id: action.actionID, what: what, how: policyText(action),
                        tone: action.policy == "ask" ? .asked : .plain))
                if let check = action.check {
                    let how = [check.status, check.note].compactMap { $0 }
                        .joined(separator: ": ")
                    checks.append(
                        Line(
                            id: action.actionID, what: what, how: how,
                            tone: check.status == "resolved"
                                ? .good : check.status == "reopened" ? .bad : .plain))
                }
            default: continue
            }
        }
        let systems = calls.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { system, _ -> String in
                // A person reads by name ("Priya"), never "person:priya · Priya".
                let person = system.hasPrefix("person:")
                var parts = [person ? PeopleDirectory.displayName(system) : system]
                if let said = words[system], !said.isEmpty {
                    parts = [said.joined(separator: ", ")]
                }
                if !person, let names = targets[system], !names.isEmpty {
                    parts.append(AryaTrim.words(names.joined(separator: ", "), limit: 36))
                }
                return parts.joined(separator: " · ")
            }
        return RunContext(
            usage: usage(stream.facts), systems: systems, policy: policy, checks: checks,
            related: related(events: events, run: run, steward: stream.steward))
    }

    /// "ran on its own · rule label", "asked a person · Replies need sign-off".
    static func policyText(_ action: ProposedActionStep) -> String {
        let decided =
            switch action.policy {
            case "auto": "ran on its own"
            case "ask": "asked a person"
            case "deny": "denied"
            default: action.policy
            }
        // "rule:person:sam.reply" names the binding too; the line already says who.
        var rule = action.rule.replacingOccurrences(of: "rule:", with: "")
        if rule.hasPrefix("person:"), let dot = rule.firstIndex(of: ".") {
            rule = String(rule[rule.index(after: dot)...])
        }
        rule = rule.isEmpty ? "" : "rule \(rule)"
        return [decided, rule].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func usage(_ facts: RunMetrics) -> String? {
        var parts: [String] = []
        if let tokens = facts.tokens, tokens > 0 {
            parts.append(
                tokens >= 1000
                    ? "\(String(format: "%.1f", Double(tokens) / 1000))k tokens"
                    : "\(tokens) tokens")
        }
        if let micros = facts.costMicros, micros > 0 { parts.append(RunMetrics.dollars(micros)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Other top-level runs of this steward that acted on a target this run acted on.
    static func related(events: [FeatureEvent], run: String, steward: String?) -> [String] {
        let mine = Set(
            events.lazy.filter { $0.run == run && $0.type == "action.proposed" }
                .compactMap { $0.payload["action"]?["target"]?.string })
        guard !mine.isEmpty else { return [] }
        var seen: [String] = []
        for event in events.reversed()
        where event.type == "action.proposed" && event.run != run && event.steward == steward {
            guard let other = event.run, !seen.contains(other),
                let target = event.payload["action"]?["target"]?.string, mine.contains(target)
            else { continue }
            seen.append(other)
            if seen.count == relatedLimit { break }
        }
        return seen
    }
}

/// The run inspector's context sections, under the facts.
struct RunContextView: View {
    let context: RunContext
    var title: (String) -> String
    var openRun: ((String) -> Void)?

    var body: some View {
        // A section shows only when it has something: an empty heading is dead chrome.
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            if !context.systems.isEmpty {
                section("Touched") {
                    ForEach(context.systems, id: \.self) { line in
                        Text(line).aryaText(AryaFont.monoSmall, AryaColor.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !context.policy.isEmpty { section("Policy") { lines(context.policy) } }
            if !context.checks.isEmpty { section("Follow-up checks") { lines(context.checks) } }
            if !context.related.isEmpty {
                section("Related runs") {
                    ForEach(context.related, id: \.self) { run in
                        Button {
                            openRun?(run)
                        } label: {
                            Text(title(run)).aryaText(AryaFont.caption, AryaColor.ink)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(openRun == nil)
                        .help(title(run))
                    }
                }
            }
        }
    }

    private func section(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(label).aryaText(AryaFont.label, AryaColor.inkFaint)
            content()
        }
    }

    private func lines(_ lines: [RunContext.Line]) -> some View {
        ForEach(lines) { line in
            VStack(alignment: .leading, spacing: 0) {
                Text(line.what).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(1)
                Text(line.how).aryaText(AryaFont.monoSmall, color(line.tone))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(_ tone: RunContext.Tone) -> Color {
        switch tone {
        case .plain: AryaColor.inkMuted
        case .asked: AryaColor.warning
        case .good: AryaColor.positive
        case .bad: AryaColor.negative
        }
    }
}
