import Foundation

/// A binding as the editor shows it. List fields are edited as comma-separated text.
struct BindingDraft: Hashable, Sendable {
    var key: Int
    var id: String
    var kind: String
    var command: String = ""
    var read: String = ""
    var actions: String = ""
    var channel: String = ""
    /// Fields the editor does not show (`args`, ...), kept as they were.
    var extra: [String: FeatureJSON] = [:]
}

/// A trigger as the editor shows it.
struct TriggerDraft: Hashable, Sendable, Identifiable {
    var key: Int
    var id: Int { key }
    var kind: String
    var everySeconds: Int = 900
    var extra: [String: FeatureJSON] = [:]
}

/// A policy rule: an action kind and its decision.
struct PolicyRuleDraft: Hashable, Sendable, Identifiable {
    var key: Int
    var id: Int { key }
    var action: String
    var decision: String
}

/// An editable copy of a charter. Saving turns it back into charter JSON for a proposal;
/// fields the editor does not cover (adapter, limits, scorer, gate, crew) pass through.
struct CharterDraft: Hashable, Sendable {
    var outcome: String
    var metricName: String
    var metricUnit: String
    var metricDirection: String
    var metricTarget: String
    var guardrails: [String]
    var bindings: [BindingDraft]
    var triggers: [TriggerDraft]
    var policyDefault: String
    var policyRules: [PolicyRuleDraft]
    var effort: String
    private(set) var base: [String: FeatureJSON]
    private var nextKey: Int

    static let decisions = ["auto", "ask", "deny"]
    static let triggerKinds = ["interval", "manual", "calendar", "message"]
    static let bindingKinds = ["mcp", "person"]

    init(charter: FeatureJSON) {
        var key = 0
        func next() -> Int {
            key += 1
            return key
        }
        base = { if case .object(let members) = charter { return members } else { return [:] } }()
        let metric = charter["metric"] ?? [:]
        outcome = charter["outcome"]?.string ?? ""
        metricName = metric["name"]?.string ?? ""
        metricUnit = metric["unit"]?.string ?? ""
        metricDirection = metric["direction"]?.string ?? "up"
        metricTarget = metric["target"]?.number.map(CharterDraft.number) ?? ""
        guardrails = charter["guardrails"]?.strings ?? []
        bindings = (charter["bindings"]?.array ?? []).map { CharterDraft.binding($0, key: next()) }
        triggers = (charter["triggers"]?.array ?? []).map { CharterDraft.trigger($0, key: next()) }
        policyDefault = charter["policy"]?["default"]?.string ?? "ask"
        policyRules = (charter["policy"]?["rules"]?.array ?? []).map { rule in
            PolicyRuleDraft(
                key: next(), action: rule["action"]?.string ?? "",
                decision: rule["decision"]?.string ?? "ask")
        }
        effort = charter["effort"]?.string ?? "medium"
        nextKey = key + 1
    }

    /// A fresh key for a new row.
    mutating func makeKey() -> Int {
        defer { nextKey += 1 }
        return nextKey
    }

    mutating func addBinding() {
        bindings.append(BindingDraft(key: makeKey(), id: "", kind: "mcp"))
    }
    mutating func addTrigger() { triggers.append(TriggerDraft(key: makeKey(), kind: "manual")) }
    mutating func addRule() {
        policyRules.append(PolicyRuleDraft(key: makeKey(), action: "", decision: "ask"))
    }

    // MARK: Validation

    /// Problems that block a proposal, in the words a person can act on.
    var issues: [String] {
        var out: [String] = []
        if trimmed(outcome).isEmpty { out.append("The outcome is empty.") }
        if trimmed(metricName).isEmpty { out.append("The metric needs a name.") }
        if !trimmed(metricTarget).isEmpty, Double(trimmed(metricTarget)) == nil {
            out.append("The metric target must be a number.")
        }
        let ids = bindings.map { trimmed($0.id) }
        if ids.contains("") { out.append("Every binding needs an id.") }
        for id in Set(ids) where !id.isEmpty && ids.filter({ $0 == id }).count > 1 {
            out.append("Binding id \(id) is used twice.")
        }
        if triggers.isEmpty { out.append("Add at least one trigger, such as manual.") }
        for trigger in triggers where trigger.kind == "interval" && trigger.everySeconds < 60 {
            out.append("Interval triggers run at most once a minute.")
        }
        // A rule may name an action no binding offers: `close: deny` guards against one.
        if policyRules.contains(where: { trimmed($0.action).isEmpty }) {
            out.append("Every policy rule needs an action.")
        }
        return out.sorted()
    }

    // MARK: Output

    /// The charter JSON this draft describes, with untouched fields carried over.
    var charter: FeatureJSON {
        var out = base
        out["outcome"] = .string(trimmed(outcome))
        var metric: [String: FeatureJSON] = [
            "name": .string(trimmed(metricName)), "unit": .string(trimmed(metricUnit)),
            "direction": .string(metricDirection),
        ]
        metric["target"] = Double(trimmed(metricTarget)).map(FeatureJSON.number)
        out["metric"] = .object(metric)
        out["guardrails"] = .array(
            guardrails.map(trimmed).filter { !$0.isEmpty }.map(FeatureJSON.string))
        out["bindings"] = .array(bindings.map(CharterDraft.json))
        out["triggers"] = .array(triggers.map(CharterDraft.json))
        out["policy"] = [
            "default": .string(policyDefault),
            "rules": .array(
                policyRules.map {
                    ["action": .string(trimmed($0.action)), "decision": .string($0.decision)]
                }),
        ]
        out["effort"] = .string(effort)
        return .object(out)
    }

    /// The top-level fields that differ from the saved charter, in charter order.
    func changedFields(from original: FeatureJSON) -> [String] {
        let fields = [
            "outcome", "metric", "guardrails", "bindings", "triggers", "policy", "effort",
        ]
        let normalized = CharterDraft(charter: original).charter
        return fields.filter { charter[$0] != normalized[$0] }
    }

    // MARK: Conversion helpers

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func binding(_ json: FeatureJSON, key: Int) -> BindingDraft {
        var extra: [String: FeatureJSON] = [:]
        if case .object(let members) = json {
            extra = members.filter {
                !["id", "kind", "command", "read", "actions", "channel"].contains($0.key)
            }
        }
        return BindingDraft(
            key: key, id: json["id"]?.string ?? "", kind: json["kind"]?.string ?? "mcp",
            command: json["command"]?.string ?? "",
            read: json["read"]?.strings.joined(separator: ", ") ?? "",
            actions: json["actions"]?.strings.joined(separator: ", ") ?? "",
            channel: json["channel"]?.string ?? "", extra: extra)
    }

    private static func trigger(_ json: FeatureJSON, key: Int) -> TriggerDraft {
        var extra: [String: FeatureJSON] = [:]
        if case .object(let members) = json {
            extra = members.filter { !["kind", "everySeconds"].contains($0.key) }
        }
        return TriggerDraft(
            key: key, kind: json["kind"]?.string ?? "manual",
            everySeconds: Int(json["everySeconds"]?.number ?? 900), extra: extra)
    }

    private static func json(_ binding: BindingDraft) -> FeatureJSON {
        var out = binding.extra
        out["id"] = .string(binding.id.trimmingCharacters(in: .whitespaces))
        out["kind"] = .string(binding.kind)
        if binding.kind == "person" {
            out["channel"] = .string(binding.channel)
        } else {
            out["command"] = .string(binding.command)
            out["read"] = .array(list(binding.read).map(FeatureJSON.string))
            out["actions"] = .array(list(binding.actions).map(FeatureJSON.string))
        }
        return .object(out)
    }

    private static func json(_ trigger: TriggerDraft) -> FeatureJSON {
        var out = trigger.extra
        out["kind"] = .string(trigger.kind)
        if trigger.kind == "interval" {
            out["everySeconds"] = .number(Double(trigger.everySeconds))
        }
        return .object(out)
    }
}

/// The live charter of a steward, from its latest `steward.created` or `charter.updated`.
struct LiveCharter: Hashable, Sendable {
    var steward: String
    var version: Int
    var charter: FeatureJSON

    static func find(events: [FeatureEvent], steward: String) -> LiveCharter? {
        var live: LiveCharter?
        for event in events where event.steward == steward {
            guard ["steward.created", "steward.charter.updated"].contains(event.type),
                let charter = event.payload["charter"]
            else { continue }
            let version = Int(event.payload["version"]?.number ?? Double((live?.version ?? 0) + 1))
            live = LiveCharter(steward: steward, version: version, charter: charter)
        }
        return live
    }
}

/// Text for the charter editor, kept apart from layout so it can be tested.
enum CharterText {
    /// "Change outcome and guardrails", the default proposal title.
    static func title(_ fields: [String]) -> String {
        switch fields.count {
        case 0: return "No changes"
        case 1: return "Change \(fields[0])"
        default:
            return "Change " + fields.dropLast().joined(separator: ", ") + " and "
                + (fields.last ?? "")
        }
    }
}
