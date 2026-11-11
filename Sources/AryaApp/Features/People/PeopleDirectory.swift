import Foundation

/// The people a steward works with, read from its live charter's person bindings: name, role,
/// how to reach them (the local inbox, or an address on a relay connection), what they may
/// approve (the charter's `policy.approvers` rules that list them, without a binding limit),
/// and how often they have written. Every edit is a gated charter proposal.
struct PeopleDirectory: Hashable, Sendable {
    struct Person: Hashable, Sendable, Identifiable {
        /// The person binding id, for example `person:alex`.
        var id: String
        var name: String
        var role: String?
        /// The local inbox (`inbox`) or their address on the relay.
        var channel: String
        /// The relay connection that carries their messages; nil is the local inbox.
        var via: String?
        /// Action kinds whose approver rule lists them (`*` for any).
        var approves: [String]
        /// Messages they sent this steward.
        var messages: Int
        var lastMessage: String?

        /// "inbox" or "sam@team via mail".
        var reach: String { via.map { "\(channel) via \($0)" } ?? channel }

    }

    /// One `policy.approvers` rule without a binding limit.
    struct ApproverRule: Hashable, Sendable {
        var action: String
        var people: [String]
    }

    var steward: String
    var live: LiveCharter?
    var people: [Person]
    /// Connections that can relay messages (MCP bindings in the live charter).
    var relays: [String]
    /// The action kinds the steward's connections offer, for the approves hint.
    var actionKinds: [String]
    /// The charter's approver rules that apply to any binding.
    var rules: [ApproverRule]

    init(events: [FeatureEvent], steward: String) {
        self.steward = steward
        live = LiveCharter.find(events: events, steward: steward)
        let bindings = live?.charter["bindings"]?.array ?? []
        var counts: [String: Int] = [:]
        var last: [String: String] = [:]
        for event in events where event.type == "inbox.message" && event.steward == steward {
            guard let from = event.payload["from"]?.string else { continue }
            counts[from, default: 0] += 1
            last[from] = event.payload["text"]?.string
        }
        let rules = (live?.charter["policy"]?["approvers"]?.array ?? []).compactMap {
            rule -> ApproverRule? in
            guard rule["binding"] == nil, let action = rule["action"]?.string else { return nil }
            return ApproverRule(
                action: action, people: rule["people"]?.array?.compactMap(\.string) ?? [])
        }
        self.rules = rules
        people = bindings.filter { $0["kind"]?.string == "person" }.compactMap { binding in
            guard let id = binding["id"]?.string else { return nil }
            return Person(
                id: id, name: binding["name"]?.string ?? Self.displayName(id),
                role: binding["role"]?.string, channel: binding["channel"]?.string ?? "inbox",
                via: binding["via"]?.string,
                approves: rules.filter { $0.people.contains(id) }.map(\.action),
                messages: counts[id] ?? 0, lastMessage: last[id])
        }
        let systems = bindings.filter { $0["kind"]?.string != "person" }
        relays = systems.compactMap { $0["id"]?.string }
        actionKinds = NewStewardDraft.unique(
            systems.flatMap { $0["actions"]?.array?.compactMap(\.string) ?? [] })
    }

    /// "person:alex" or "alex" → "Alex", and the person at this home → "you": the one rule in
    /// `HumanText.actor`, so names read the same on every screen.
    static func displayName(_ id: String) -> String {
        HumanText.actor(
            id.contains(":") || HumanText.localIDs.contains(id) ? id : "person:" + id)
    }

    /// Who may approve `kind` under the most specific rule (the kind's, else `*`), as the
    /// rule lists them (`local` is the person at this home); nil when no rule covers it and
    /// anyone may.
    func approvers(of kind: String) -> [String]? {
        (rules.first { $0.action == kind } ?? rules.first { $0.action == "*" })?.people
    }

    /// A display name for an approver id: "You" for `local`, else the person's name.
    func approverName(_ id: String) -> String {
        if id == "local" { return "You" }
        guard let person = people.first(where: { $0.id == id }) else {
            return Self.displayName(id)
        }
        return person.role.map { "\(person.name) (\($0))" } ?? person.name
    }

    /// `policy` with `id` listed on exactly `kinds` among rules without a binding limit. A rule
    /// left with no one names `local`, so it never silently opens to anyone; a new rule lists
    /// `local` and the person, so the person at this home can still approve.
    static func policy(_ policy: FeatureJSON?, listing id: String, on kinds: [String])
        -> FeatureJSON
    {
        guard case .object(var members) = policy ?? .object([:]) else { return policy ?? .null }
        var rules = members["approvers"]?.array ?? []
        var covered = Set<String>()
        for index in rules.indices {
            guard case .object(var rule) = rules[index], rule["binding"] == nil,
                let action = rule["action"]?.string
            else { continue }
            var people = rule["people"]?.array?.compactMap(\.string) ?? []
            if kinds.contains(action) {
                covered.insert(action)
                if !people.contains(id) { people.append(id) }
            } else {
                people.removeAll { $0 == id }
                if people.isEmpty { people = ["local"] }
            }
            rule["people"] = .array(people.map(FeatureJSON.string))
            rules[index] = .object(rule)
        }
        for kind in kinds where !covered.contains(kind) {
            rules.append(["action": .string(kind), "people": ["local", .string(id)]])
        }
        members["approvers"] = rules.isEmpty ? nil : .array(rules)
        return .object(members)
    }

    /// A proposal adding `draft` as a new person, or updating the person `editing` keeps (its
    /// id, and fields the directory does not manage, such as the reply actions, stay).
    func saveProposal(_ draft: PersonDraft, editing: String?) -> CharterProposal? {
        guard let live, case .object(var charter) = live.charter, draft.issues.isEmpty else {
            return nil
        }
        var bindings = live.charter["bindings"]?.array ?? []
        let id = editing ?? draft.bindingID
        let index = bindings.firstIndex { $0["id"]?.string == id }
        if index == nil, editing != nil { return nil }
        if index != nil, editing == nil { return nil }
        var members: [String: FeatureJSON] = [:]
        if let index, case .object(let existing) = bindings[index] { members = existing }
        members["id"] = .string(id)
        members["kind"] = "person"
        members["name"] = .string(draft.name.trimmed)
        members["role"] = draft.role.trimmed.isEmpty ? nil : .string(draft.role.trimmed)
        members["channel"] = .string(
            draft.channel.trimmed.isEmpty ? "inbox" : draft.channel.trimmed)
        members["via"] = draft.via.isEmpty ? nil : .string(draft.via)
        if let index {
            bindings[index] = .object(members)
        } else {
            bindings.append(.object(members))
        }
        charter["bindings"] = .array(bindings)
        charter["policy"] = Self.policy(
            live.charter["policy"], listing: id, on: NewStewardDraft.list(draft.approves))
        let verb = editing == nil ? "Add" : "Update"
        return CharterProposal(
            steward: steward, baseVersion: live.version, charter: .object(charter),
            title: "\(verb) \(draft.name.trimmed)", reason: draft.reason)
    }

    /// A proposal removing person `id`, and any message trigger that names them.
    func removeProposal(_ id: String) -> CharterProposal? {
        guard let live, case .object(var charter) = live.charter,
            let person = people.first(where: { $0.id == id })
        else { return nil }
        charter["bindings"] = .array(
            (live.charter["bindings"]?.array ?? []).filter { $0["id"]?.string != id })
        charter["policy"] = Self.policy(live.charter["policy"], listing: id, on: [])
        if let triggers = live.charter["triggers"]?.array {
            charter["triggers"] = .array(triggers.filter { $0["from"]?.string != id })
        }
        return CharterProposal(
            steward: steward, baseVersion: live.version, charter: .object(charter),
            title: "Remove \(person.name)", reason: "No longer works with \(person.name).")
    }
}

/// The person form's answers.
struct PersonDraft: Hashable, Sendable {
    var name = ""
    var role = ""
    var channel = "inbox"
    /// The relay connection id; empty is the local inbox.
    var via = ""
    /// Comma-separated action kinds, or `*`.
    var approves = ""

    init() {}

    init(_ person: PeopleDirectory.Person) {
        name = person.name
        role = person.role ?? ""
        channel = person.channel
        via = person.via ?? ""
        approves = person.approves.joined(separator: ", ")
    }

    var bindingID: String { "person:" + NewStewardDraft.slug(name) }

    /// What blocks saving, phrased for people.
    var issues: [String] {
        var out: [String] = []
        if name.trimmed.isEmpty { out.append("Give the person a name.") }
        if !via.isEmpty, channel.trimmed.isEmpty || channel.trimmed == "inbox" {
            out.append("Give their address on \(via).")
        }
        return out
    }

    var reason: String {
        let approves = NewStewardDraft.list(approves)
        var out = "Works with \(name.trimmed)"
        if !role.trimmed.isEmpty { out += ", \(role.trimmed)," }
        out += via.isEmpty ? " through the local inbox" : " through \(via)"
        if !approves.isEmpty { out += "; may approve " + approves.joined(separator: ", ") }
        return out + "."
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
