import Arya
import Foundation

/// The live charter an edit started from.
struct CharterEditing: Hashable, Sendable {
    var steward: String
    /// The live version the draft started from; the facade refuses the proposal if it moved.
    var baseVersion: Int
    var live: FeatureJSON
}

/// Editing a live charter with the New steward steps: the answers are read from the charter,
/// and the edits are merged back into it, keeping every field the steps do not manage
/// (limits, scorer, gate, crew, risk levels, autonomy). The result is a gated proposal.
extension NewStewardDraft {
    /// The owner as the charter stores it: the live ref when the name is unchanged, a typed
    /// ref as typed, else a person ref from the name ("Priya Shah" is `person:priya-shah`).
    static func ownerRef(_ name: String, live: String?) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        if let live, HumanText.actor(live) == name { return live }
        if name.contains(":") { return name }
        return "person:" + name.lowercased().split(separator: " ").joined(separator: "-")
    }

    /// The steps prefilled from `live`.
    static func editing(_ live: LiveCharter) -> NewStewardDraft {
        let charter = live.charter
        var draft = NewStewardDraft()
        draft.editing = CharterEditing(
            steward: live.steward, baseVersion: live.version, live: charter)
        draft.name = charter["name"]?.string ?? ""
        draft.outcome = charter["outcome"]?.string ?? ""
        draft.owner = charter["owner"]?.string.map(HumanText.actor) ?? ""
        draft.guardrailMetrics = (charter["guardrailMetrics"]?.array ?? []).enumerated().map {
            index, metric in
            GuardrailMetric(
                id: index + 1, name: metric["name"]?.string ?? "",
                direction: metric["direction"]?.string ?? "down",
                target: metric["target"]?.number.map { Self.number($0) } ?? "",
                unit: metric["unit"]?.string ?? "")
        }
        draft.metric = charter["metric"]?["name"]?.string ?? ""
        draft.unit = charter["metric"]?["unit"]?.string ?? ""
        draft.direction = charter["metric"]?["direction"]?.string ?? "up"
        draft.target = charter["metric"]?["target"]?.number.map { Self.number($0) } ?? ""
        draft.guardrails = (charter["guardrails"]?.array ?? []).compactMap(\.string)
            .joined(separator: "\n")
        draft.autonomy = charter["policy"]?["default"]?.string == "auto" ? .auto : .ask
        var asks = Set<String>()
        var ruled = Set<String>()
        for rule in charter["policy"]?["rules"]?.array ?? [] {
            guard let action = rule["action"]?.string else { continue }
            ruled.insert(action)
            switch rule["decision"]?.string {
            case "deny": draft.never.insert(action)
            case "ask": asks.insert(action)
            default: break
            }
        }
        draft.people = []
        for (index, binding) in (charter["bindings"]?.array ?? []).enumerated() {
            guard let id = binding["id"]?.string else { continue }
            if binding["kind"]?.string == "person" {
                let name = id.hasPrefix("person:") ? String(id.dropFirst(7)) : id
                let channel = binding["channel"]?.string ?? "inbox"
                draft.people.append(Person(id: index, name: name, channel: channel))
                if !draft.channels.contains(channel) { draft.channels.append(channel) }
            } else if let command = binding["command"]?.string {
                draft.connections.append(
                    Connection(
                        id: id, command: command,
                        args: binding["args"]?.array?.compactMap(\.string) ?? [],
                        read: binding["read"]?.array?.compactMap(\.string) ?? [],
                        actions: binding["actions"]?.array?.compactMap(\.string) ?? [],
                        isOn: true))
            }
        }
        if draft.people.isEmpty { draft.people = [Person(id: 0)] }
        // An action with no rule follows the charter's default.
        let unruled = draft.actionKinds.filter { !ruled.contains($0) }
        draft.signOff = asks.union(draft.autonomy == .ask ? unruled : [])
        let triggers = charter["triggers"]?.array ?? []
        draft.everyMinutes =
            triggers.first { $0["kind"]?.string == "interval" }?["everySeconds"]?.number
            .map { String(Int($0) / 60) } ?? ""
        draft.wakesOnMessage = triggers.contains { $0["kind"]?.string == "message" }
        draft.effort = charter["effort"]?.string ?? "medium"
        draft.adapter = charter["adapter"]?.string ?? "default"
        return draft
    }

    /// The live charter with the edits merged in.
    func proposedCharter() -> FeatureJSON {
        guard let editing, case .object(var out) = editing.live else { return .null }
        let draft = stewardDraft()
        out["name"] = .string(draft.name)
        out["outcome"] = .string(draft.outcome)
        var metric = Self.members(editing.live["metric"])
        metric["name"] = .string(draft.metric)
        metric["unit"] = .string(draft.unit)
        metric["direction"] = .string(draft.direction)
        metric["target"] = draft.target.map(FeatureJSON.number)
        out["metric"] = .object(metric)
        out["owner"] = draft.owner.map {
            FeatureJSON.string(Self.ownerRef($0, live: editing.live["owner"]?.string))
        }
        out["guardrailMetrics"] =
            guardrailMetrics.isEmpty ? nil : .array(guardrailMetrics.map(\.json))
        out["guardrails"] = .array(draft.guardrails.map(FeatureJSON.string))
        var policy = Self.members(editing.live["policy"])
        policy["default"] = .string(draft.autonomy)
        // Each rule keeps the live rule's other fields (a note, a binding) for the same action;
        // kinds the live charter left to its default stay unruled while they still match it.
        let liveRules = (editing.live["policy"]?["rules"]?.array ?? []).reduce(
            into: [String: [String: FeatureJSON]]()
        ) { if let action = $1["action"]?.string { $0[action] = Self.members($1) } }
        let rules = draft.rules.filter {
            liveRules[$0.action] != nil || $0.decision != draft.autonomy
        }
        policy["rules"] = .array(
            rules.map { rule in
                var out = liveRules[rule.action] ?? [:]
                out["action"] = .string(rule.action)
                out["decision"] = .string(rule.decision)
                return .object(out)
            })
        out["policy"] = .object(policy)
        out["bindings"] = .array(bindings(draft.bindings, live: editing.live["bindings"]))
        out["triggers"] = .array(triggers(draft.triggers, live: editing.live["triggers"]))
        out["effort"] = .string(draft.effort)
        out["adapter"] = .string(draft.adapter)
        return .object(out)
    }

    /// What the edit changes, in the steps' words, in step order.
    func changedFields() -> [String] {
        guard let editing else { return [] }
        let proposed = proposedCharter()
        let fields: [(String, [String])] = [
            ("name", ["name"]), ("outcome", ["outcome"]), ("owner", ["owner"]),
            ("metric", ["metric", "guardrailMetrics"]),
            ("connections", ["bindings"]), ("guardrails", ["guardrails"]),
            ("sign-off", ["policy"]), ("schedule", ["triggers", "effort", "adapter"]),
        ]
        return fields.filter { _, keys in
            keys.contains {
                Self.normalized($0, proposed[$0]) != Self.normalized($0, editing.live[$0])
            }
        }
        .map(\.0)
    }

    /// "This changes the outcome and sign-off. It goes live after rehearsal passes."
    static func changeLine(_ fields: [String]) -> String {
        let list =
            fields.count < 2
            ? fields.joined()
            : fields.dropLast().joined(separator: ", ") + " and " + (fields.last ?? "")
        return "This changes the \(list). It goes live after rehearsal passes."
    }

    /// The gated proposal for the edit.
    func proposal() -> CharterProposal? {
        guard let editing else { return nil }
        return CharterProposal(
            steward: editing.steward, baseVersion: editing.baseVersion,
            charter: proposedCharter(), title: CharterText.title(changedFields()),
            reason: whyChange.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Merging

    /// Each binding keeps the live binding's other fields when its id was already there.
    private func bindings(_ drafted: [StewardDraft.Binding], live: FeatureJSON?) -> [FeatureJSON] {
        let old = (live?.array ?? []).reduce(into: [String: [String: FeatureJSON]]()) {
            if let id = $1["id"]?.string { $0[id] = Self.members($1) }
        }
        return drafted.map { binding in
            var out = old[binding.id] ?? [:]
            out["id"] = .string(binding.id)
            out["kind"] = .string(binding.kind)
            if binding.kind == "person" {
                out["channel"] = binding.channel.map(FeatureJSON.string)
            } else {
                out["command"] = binding.command.map(FeatureJSON.string)
                out["args"] = .array(binding.args.map(FeatureJSON.string))
                out["actions"] = .array(binding.actions.map(FeatureJSON.string))
                if !binding.read.isEmpty || out["read"] != nil {
                    out["read"] = .array(binding.read.map(FeatureJSON.string))
                }
            }
            return .object(out)
        }
    }

    /// Triggers the steps manage (interval, message) replace the live ones; others stay, and
    /// manual stays only if it was there.
    private func triggers(_ drafted: [StewardDraft.Trigger], live: FeatureJSON?) -> [FeatureJSON] {
        let old = live?.array ?? []
        let hadManual = old.contains { $0["kind"]?.string == "manual" }
        var out = old.filter {
            !["manual", "interval", "message"].contains($0["kind"]?.string ?? "")
        }
        for trigger in drafted where trigger.kind != "manual" || hadManual {
            var item: [String: FeatureJSON] = ["kind": .string(trigger.kind)]
            if let every = trigger.everySeconds { item["everySeconds"] = .number(Double(every)) }
            out.append(.object(item))
        }
        return out
    }

    private static func members(_ json: FeatureJSON?) -> [String: FeatureJSON] {
        if case .object(let members)? = json { return members }
        return [:]
    }

    /// Order-insensitive lists, so reordering alone is not a change.
    private static func normalized(_ key: String, _ json: FeatureJSON?) -> FeatureJSON? {
        func sorted(_ items: [FeatureJSON], by field: String) -> FeatureJSON {
            .array(items.sorted { ($0[field]?.string ?? "") < ($1[field]?.string ?? "") })
        }
        switch key {
        case "bindings": return json?.array.map { sorted($0, by: "id") } ?? json
        case "triggers": return json?.array.map { sorted($0, by: "kind") } ?? json
        case "policy":
            var policy = members(json)
            policy["rules"] = policy["rules"]?.array.map { sorted($0, by: "action") }
            return .object(policy)
        default: return json
        }
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}
