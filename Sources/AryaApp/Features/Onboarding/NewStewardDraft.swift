import Arya
import Foundation

/// The New steward flow's answers. Connections, people, and sign-off are picked with controls,
/// never typed as config; guardrails are one per line. `stewardDraft()` turns the answers into
/// the facade's `StewardDraft`.
struct NewStewardDraft: Hashable, Sendable {
    /// The flow's steps, one question group each.
    enum Step: Int, CaseIterable, Hashable, Sendable {
        /// Connections come before guardrails so sign-off can list the actions they offer.
        case outcome, metric, connections, guardrails, schedule

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

        /// What the choice does: it only sets where the sign-off checklist starts.
        var hint: String {
            switch self {
            case .ask: "Every action asks you first; uncheck the ones it may do on its own."
            case .auto: "Only high-risk actions start checked; the rest run on their own."
            }
        }
    }

    /// A system the steward can work in: a known binding to switch on, or a custom command.
    struct Connection: Hashable, Sendable, Identifiable {
        var id: String
        var command: String
        var args: [String] = []
        var read: [String] = []
        var actions: [String] = []
        var isOn = false

        var binding: StewardDraft.Binding {
            StewardDraft.Binding(
                id: id, kind: "mcp", command: command, args: args, read: read, actions: actions)
        }
    }

    /// A person the steward works with: a name and how to reach them.
    struct Person: Hashable, Sendable, Identifiable {
        var id: Int
        var name = ""
        var channel = "inbox"

        var bindingID: String { "person:" + NewStewardDraft.slug(name) }
    }

    var name = ""
    var outcome = ""
    /// Who answers for the outcome: a person's name or person binding id; empty for none.
    var owner = ""
    /// Metrics that must hold while the primary moves (a quality or cost bound).
    var guardrailMetrics: [GuardrailMetric] = []
    var metric = ""
    var unit = "ratio"
    var target = ""
    var direction = "up"
    /// One guardrail per line: what it must never do.
    var guardrails = ""
    var autonomy = Autonomy.ask
    /// Action kinds the person picked as needing sign-off; `nil` follows the autonomy default.
    var signOff: Set<String>?
    /// Action kinds it may never take.
    var never: Set<String> = []
    /// Known connections to switch on.
    var connections: [Connection] = []
    /// A custom connection (Advanced): its id, command line, and the actions it offers.
    var customID = ""
    var customCommand = ""
    var customActions = ""
    var people: [Person] = [Person(id: 0)]
    /// Channels offered for people.
    var channels = ["inbox", "email", "chat"]
    /// Risk by action kind, from the workspace (`NewStewardCatalog`).
    var risks: [String: String] = [:]
    /// Minutes between scheduled wakes; empty or 0 means only when asked.
    var everyMinutes = "15"
    var wakesOnMessage = true
    var effort = "medium"
    var adapter = "default"
    /// Carried from a template: the department it serves and its autonomy level.
    var department = ""
    var level: String?

    /// One guardrail metric row: its name, which way is better, its bound, and its unit.
    struct GuardrailMetric: Hashable, Sendable, Identifiable {
        var id: Int
        var name = ""
        var direction = "down"
        var target = ""
        var unit = "ratio"

        var json: FeatureJSON {
            var out: [String: FeatureJSON] = [
                "name": .string(name.trimmed), "unit": .string(unit.trimmed),
                "direction": .string(direction),
            ]
            out["target"] = Double(target.trimmed).map(FeatureJSON.number)
            return .object(out)
        }
    }

    mutating func addGuardrailMetric() {
        guardrailMetrics.append(GuardrailMetric(id: (guardrailMetrics.map(\.id).max() ?? 0) + 1))
    }
    /// Set when the flow edits a live charter (`CharterEdit.swift`); it then ends in a
    /// proposal, never a direct save.
    var editing: CharterEditing?
    /// Why the change, for the proposal (edit only).
    var whyChange = ""

    /// The steward id: the edited steward's, or the facade's `st_` and the name's slug.
    var stewardID: String { editing?.steward ?? "st_" + Self.slug(name) }

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
            let names = guardrailMetrics.map(\.name.trimmed)
            if names.contains("") { out.append("Name each guardrail metric, or remove it.") }
            for row in guardrailMetrics where !row.name.trimmed.isEmpty {
                if !row.target.trimmed.isEmpty, Double(row.target.trimmed) == nil {
                    out.append("The bound for \(row.name.trimmed) must be a number.")
                }
                if row.name.trimmed == metric.trimmed {
                    out.append("\(row.name.trimmed) is already the main metric.")
                }
            }
            if Set(names).count < names.count { out.append("A guardrail metric is listed twice.") }
            return out
        case .guardrails:
            return []
        case .connections:
            var out: [String] = []
            if !customCommand.trimmed.isEmpty, customID.trimmed.isEmpty {
                out.append("Name the custom connection.")
            }
            if !customID.trimmed.isEmpty, customCommand.trimmed.isEmpty {
                out.append("Give the custom connection a command to run.")
            }
            let ids = namedPeople.map(\.bindingID)
            if Set(ids).count < ids.count { out.append("Each person needs a different name.") }
            return out
        case .schedule:
            var out: [String] = []
            let minutes = everyMinutes.trimmed
            if !minutes.isEmpty, Int(minutes).map({ $0 >= 0 }) != true {
                out.append("Minutes must be a whole number, or empty for on demand.")
            }
            if adapter.trimmed.isEmpty { out.append("Name the adapter profile to run it with.") }
            if editing != nil, out.isEmpty, changedFields().isEmpty {
                out.append("Nothing changed yet.")
            }
            return out
        }
    }

    /// Whether every step is complete.
    var isComplete: Bool { Step.allCases.allSatisfy { problems($0).isEmpty } }

    /// Switched-on connections, the custom one last.
    var chosenConnections: [Connection] {
        var out = connections.filter(\.isOn)
        if !customID.trimmed.isEmpty, !customCommand.trimmed.isEmpty {
            let words = customCommand.split(separator: " ").map(String.init)
            out.append(
                Connection(
                    id: customID.trimmed, command: words[0], args: Array(words.dropFirst()),
                    actions: Self.list(customActions), isOn: true))
        }
        return out
    }

    var namedPeople: [Person] { people.filter { !$0.name.trimmed.isEmpty } }

    /// The action kinds the chosen connections offer, in order.
    var actionKinds: [String] { Self.unique(chosenConnections.flatMap(\.actions)) }

    /// The runtime's default risk by action kind (mirrored until the facade risk read lands;
    /// switch to it then), and `medium` for any other kind.
    static let defaultRisks = [
        "label": "low", "route": "low", "reply": "medium", "close": "high", "refund": "high",
    ]
    static let defaultRisk = "medium"

    /// `low`, `medium`, or `high`, as the runtime would resolve it: the workspace's charter
    /// entry or recorded resolution for the kind, else the runtime default for the kind.
    func risk(_ kind: String) -> String {
        risks[kind] ?? Self.defaultRisks[kind] ?? Self.defaultRisk
    }

    /// One muted line under autonomy that matches the checklist as it stands.
    var signOffHint: String {
        if signOff != nil { return "Checked actions wait for you; the rest run on their own." }
        return autonomy.hint
    }

    /// Whether `kind` waits for a person: as picked, else everything when asking first, and
    /// only high-risk actions when acting on its own.
    func needsSignOff(_ kind: String) -> Bool {
        if never.contains(kind) { return false }
        if let signOff { return signOff.contains(kind) }
        return autonomy == .ask || risk(kind) == "high"
    }

    mutating func setSignOff(_ kind: String, _ on: Bool) {
        var picked = signOff ?? Set(actionKinds.filter(needsSignOff))
        if on { picked.insert(kind) } else { picked.remove(kind) }
        signOff = picked
        if on { never.remove(kind) }
    }

    mutating func setNever(_ kind: String, _ on: Bool) {
        if on { never.insert(kind) } else { never.remove(kind) }
    }

    mutating func addPerson() {
        people.append(Person(id: (people.map(\.id).max() ?? -1) + 1, channel: channels[0]))
    }

    /// Adds what the workspace already knows: connections other stewards use (off), the
    /// channels people are reached on, and recorded risks.
    mutating func adopt(_ catalog: NewStewardCatalog) {
        for known in catalog.connections where !connections.contains(where: { $0.id == known.id }) {
            connections.append(known)
        }
        channels = Self.unique(channels + catalog.channels)
        risks.merge(catalog.risks) { mine, _ in mine }
    }

    /// The facade's structured draft. Each connection offers its own actions; every action
    /// kind gets a rule: never → deny, sign-off → ask, else auto.
    func stewardDraft() -> StewardDraft {
        var bindings = chosenConnections.map(\.binding)
        bindings += namedPeople.map {
            StewardDraft.Binding(id: $0.bindingID, kind: "person", channel: $0.channel)
        }
        var rules = actionKinds.map { kind in
            StewardDraft.Rule(
                action: kind,
                decision: never.contains(kind) ? "deny" : needsSignOff(kind) ? "ask" : "auto")
        }
        rules += never.subtracting(actionKinds).sorted().map {
            StewardDraft.Rule(action: $0, decision: "deny")
        }
        var triggers: [StewardDraft.Trigger] = [StewardDraft.Trigger(kind: "manual")]
        if let minutes = Int(everyMinutes.trimmed), minutes > 0 {
            triggers.append(StewardDraft.Trigger(kind: "interval", everySeconds: minutes * 60))
        }
        if wakesOnMessage { triggers.append(StewardDraft.Trigger(kind: "message")) }
        return StewardDraft(
            id: stewardID, name: name.trimmed, outcome: outcome.trimmed, metric: metric.trimmed,
            unit: unit.trimmed, direction: direction, target: Double(target.trimmed),
            guardrails: Self.lines(guardrails), autonomy: autonomy.rawValue, rules: rules,
            bindings: bindings, effort: effort, triggers: triggers, adapter: adapter.trimmed,
            level: level, owner: owner.trimmed.isEmpty ? nil : owner.trimmed,
            department: department.trimmed.isEmpty ? nil : department.trimmed)
    }

    /// A filled-in example: the generic support-inbox steward the demo home uses.
    static let example = NewStewardDraft(
        name: "Support inbox triage",
        outcome:
            "Every new message in the support inbox is labeled and routed to the right queue "
            + "within one hour.",
        metric: "routed_within_1h", unit: "ratio", target: "0.95", direction: "up",
        guardrails: "Never close a conversation.\nNever promise a refund.",
        autonomy: .ask, signOff: ["reply"], never: ["close"],
        connections: [
            Connection(
                id: "inbox", command: "inbox-mcp", read: ["search", "get"],
                actions: ["label", "route", "reply", "close"], isOn: true)
        ],
        people: [Person(id: 0, name: "alex", channel: "inbox")], everyMinutes: "15",
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

/// What the workspace already knows that the New steward flow can offer: connections other
/// stewards use, the channels people are reached on, and the risk of each action kind.
struct NewStewardCatalog: Hashable, Sendable {
    var connections: [NewStewardDraft.Connection] = []
    var channels: [String] = []
    var risks: [String: String] = [:]

    init(events: [FeatureEvent]) {
        var byID: [String: NewStewardDraft.Connection] = [:]
        var order: [String] = []
        for event in events where event.type == "steward.created" || event.type == "steward.updated"
        {
            for binding in event.payload["charter"]?["bindings"]?.array ?? [] {
                guard let id = binding["id"]?.string else { continue }
                if binding["kind"]?.string == "person" {
                    if let channel = binding["channel"]?.string { channels.append(channel) }
                    continue
                }
                guard let command = binding["command"]?.string else { continue }
                if byID[id] == nil { order.append(id) }
                byID[id] = NewStewardDraft.Connection(
                    id: id, command: command,
                    args: binding["args"]?.array?.compactMap(\.string) ?? [],
                    read: binding["read"]?.array?.compactMap(\.string) ?? [],
                    actions: binding["actions"]?.array?.compactMap(\.string) ?? [])
            }
        }
        connections = order.compactMap { byID[$0] }
        channels = NewStewardDraft.unique(channels)
        // One source with the runtime and the approval views: the risk the runtime resolved
        // on `action.proposed`, overridden by a charter's `policy.risk` entry for the kind.
        for event in events where event.type == "action.proposed" {
            if let kind = event.payload["action"]?["kind"]?.string,
                let risk = event.payload["risk"]?.string
            {
                risks[kind] = risk
            }
        }
        for event in events where event.type == "steward.created" || event.type == "steward.updated"
        {
            for rule in event.payload["charter"]?["policy"]?["risk"]?.array ?? [] {
                guard rule["binding"]?.string == nil, let kind = rule["action"]?.string,
                    let level = rule["level"]?.string
                else { continue }
                risks[kind] = level
            }
        }
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
        var charter: [String: FeatureJSON] = [
            "v": 1, "id": .string(draft.id ?? ""), "name": .string(draft.name),
            "outcome": .string(draft.outcome), "metric": .object(metric),
            "guardrails": .array(draft.guardrails.map(FeatureJSON.string)),
            "policy": ["default": .string(draft.autonomy), "rules": .array(rules)],
            "triggers": .array(triggers), "adapter": .string(draft.adapter),
            "effort": .string(draft.effort),
        ]
        charter["owner"] = draft.owner.map(FeatureJSON.string)
        return .object(charter)
    }
}
