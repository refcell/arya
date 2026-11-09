import Arya
import Foundation

/// The New steward flow's answers, as the person types them. Lists are one item per line so
/// nobody writes JSON. `stewardDraft()` turns them into the facade's `StewardDraft`.
struct NewStewardDraft: Hashable, Sendable {
    /// The flow's steps, one question group each.
    enum Step: Int, CaseIterable, Hashable, Sendable {
        case outcome, metric, guardrails, connections, schedule

        var title: String {
            switch self {
            case .outcome: "Outcome"
            case .metric: "Metric and target"
            case .guardrails: "Guardrails and sign-off"
            case .connections: "Connections"
            case .schedule: "Schedule"
            }
        }

        /// The question the step asks, in one line.
        var question: String {
            switch self {
            case .outcome: "What outcome should this steward own?"
            case .metric: "How will you know it is working?"
            case .guardrails: "What must it never do, and what needs your sign-off?"
            case .connections: "Which systems and people does it work with?"
            case .schedule: "When should it wake up?"
            }
        }

        var next: Step? { Step(rawValue: rawValue + 1) }
        var previous: Step? { Step(rawValue: rawValue - 1) }
    }

    enum Autonomy: String, CaseIterable, Hashable, Sendable {
        /// Policy default `ask`: everything waits for a person unless listed as automatic.
        case ask
        /// Policy default `auto`: acts on its own unless an action needs sign-off.
        case auto

        var label: String { self == .ask ? "Ask before acting" : "Act on its own" }
    }

    var name = ""
    var outcome = ""
    var metric = ""
    var unit = "ratio"
    var target = ""
    var direction = "up"
    /// One guardrail per line: what it must never do.
    var guardrails = ""
    var autonomy = Autonomy.ask
    /// Action kinds it may take on its own, comma separated (`label, comment`).
    var automatic = ""
    /// Action kinds that always need sign-off.
    var signOff = ""
    /// Action kinds it may never take.
    var never = ""
    /// One system per line: `id: command args`.
    var systems = ""
    /// One person per line: `person:alex` or `person:alex email`.
    var people = ""
    /// Minutes between scheduled wakes; empty or 0 means only when asked.
    var everyMinutes = "15"
    var wakesOnMessage = true
    var effort = "medium"
    var adapter = "default"

    /// The steward id the facade will record: `st_` and the name's slug.
    var stewardID: String { "st_" + Self.slug(name) }

    /// What blocks Continue on `step`, phrased for people; empty when the step is complete.
    func problems(_ step: Step) -> [String] {
        switch step {
        case .outcome:
            return [
                name.trimmed.isEmpty ? "Give it a name." : nil,
                outcome.trimmed.isEmpty ? "Write the outcome in one sentence." : nil,
            ].compactMap { $0 }
        case .metric:
            var out: [String] = []
            if metric.trimmed.isEmpty { out.append("Name the metric it moves.") }
            if !target.trimmed.isEmpty, Double(target.trimmed) == nil {
                out.append("The target must be a number, like 0.95.")
            }
            return out
        case .guardrails:
            let both = Set(Self.list(automatic)).intersection(Self.list(signOff)).sorted()
            if both.isEmpty { return [] }
            return ["\(both.joined(separator: ", ")) cannot be automatic and need sign-off."]
        case .connections:
            return systemLines().compactMap(\.problem) + personLines().compactMap(\.problem)
        case .schedule:
            let minutes = everyMinutes.trimmed
            if !minutes.isEmpty, Int(minutes).map({ $0 >= 0 }) != true {
                return ["Minutes must be a whole number, or empty for on demand."]
            }
            return adapter.trimmed.isEmpty ? ["Name the adapter profile to run it with."] : []
        }
    }

    /// Whether every step is complete.
    var isComplete: Bool { Step.allCases.allSatisfy { problems($0).isEmpty } }

    /// The facade's structured draft. Every automatic or sign-off action kind is offered by
    /// the first system, since the person did not split them per system.
    func stewardDraft() -> StewardDraft {
        let actions = Self.unique(Self.list(automatic) + Self.list(signOff))
        var bindings = systemLines().compactMap(\.binding)
        if !bindings.isEmpty { bindings[0].actions = actions }
        bindings += personLines().compactMap(\.binding)
        var rules = Self.list(automatic).map { StewardDraft.Rule(action: $0, decision: "auto") }
        rules += Self.list(signOff).map { StewardDraft.Rule(action: $0, decision: "ask") }
        rules += Self.list(never).map { StewardDraft.Rule(action: $0, decision: "deny") }
        var triggers: [StewardDraft.Trigger] = [StewardDraft.Trigger(kind: "manual")]
        if let minutes = Int(everyMinutes.trimmed), minutes > 0 {
            triggers.append(StewardDraft.Trigger(kind: "interval", everySeconds: minutes * 60))
        }
        if wakesOnMessage { triggers.append(StewardDraft.Trigger(kind: "message")) }
        return StewardDraft(
            id: stewardID, name: name.trimmed, outcome: outcome.trimmed, metric: metric.trimmed,
            unit: unit.trimmed, direction: direction, target: Double(target.trimmed),
            guardrails: Self.lines(guardrails), autonomy: autonomy.rawValue, rules: rules,
            bindings: bindings, effort: effort, triggers: triggers, adapter: adapter.trimmed)
    }

    /// A parsed line of the systems or people list.
    struct Line: Hashable, Sendable {
        var binding: StewardDraft.Binding?
        var problem: String?
    }

    func systemLines() -> [Line] {
        Self.lines(systems).map { line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            let words = (parts.count == 2 ? parts[1] : "").split(separator: " ").map(String.init)
            guard parts.count == 2, let command = words.first, !parts[0].trimmed.isEmpty else {
                return Line(problem: "Write each system as `id: command`, not `\(line)`.")
            }
            return Line(
                binding: StewardDraft.Binding(
                    id: parts[0].trimmed, kind: "mcp", command: command,
                    args: Array(words.dropFirst())))
        }
    }

    func personLines() -> [Line] {
        Self.lines(people).map { line in
            let words = line.split(separator: " ").map(String.init)
            guard let first = words.first, words.count <= 2 else {
                return Line(problem: "Write each person as `person:alex` and a channel.")
            }
            let id = first.hasPrefix("person:") ? first : "person:\(first)"
            return Line(
                binding: StewardDraft.Binding(
                    id: id, kind: "person", channel: words.count == 2 ? words[1] : "inbox"))
        }
    }

    /// A filled-in example: the generic support-inbox steward the demo home uses.
    static let example = NewStewardDraft(
        name: "Support inbox triage",
        outcome:
            "Every new message in the support inbox is labeled and routed to the right queue "
            + "within one hour.",
        metric: "routed_within_1h", unit: "ratio", target: "0.95", direction: "up",
        guardrails: "Never close a conversation.\nNever promise a refund.",
        autonomy: .ask, automatic: "label, route", signOff: "reply", never: "close",
        systems: "inbox: inbox-mcp", people: "person:alex inbox", everyMinutes: "15",
        wakesOnMessage: true, effort: "medium", adapter: "default")

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { String($0).trimmed }
            .filter { !$0.isEmpty }
    }

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// The facade's slug: lowercase letters and digits, runs of anything else as one `_`.
    static func slug(_ name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != "_" {
                out.append("_")
            }
        }
        while out.last == "_" { out.removeLast() }
        return out.isEmpty ? "steward" : out
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The charter JSON the preview workspace records for a created steward, in the shape of
/// ARCHITECTURE.md (the facade builds the real one from the same draft).
enum NewStewardPreview {
    static func charter(_ draft: StewardDraft) -> FeatureJSON {
        var metric: [String: FeatureJSON] = [
            "name": .string(draft.metric), "unit": .string(draft.unit),
            "direction": .string(draft.direction),
        ]
        if let target = draft.target { metric["target"] = .number(target) }
        let rules = draft.rules.map { rule -> FeatureJSON in
            .object(["action": .string(rule.action), "decision": .string(rule.decision)])
        }
        let triggers = draft.triggers.map { trigger -> FeatureJSON in
            var out: [String: FeatureJSON] = ["kind": .string(trigger.kind)]
            if let every = trigger.everySeconds { out["everySeconds"] = .number(Double(every)) }
            return .object(out)
        }
        return .object([
            "v": 1, "id": .string(draft.id ?? ""), "name": .string(draft.name),
            "outcome": .string(draft.outcome), "metric": .object(metric),
            "guardrails": .array(draft.guardrails.map(FeatureJSON.string)),
            "policy": ["default": .string(draft.autonomy), "rules": .array(rules)],
            "triggers": .array(triggers), "adapter": .string(draft.adapter),
            "effort": .string(draft.effort),
        ])
    }
}
