import Foundation

/// Everyone any steward works with, once each: the person bindings across live charters,
/// merged by binding id, with the stewards they work with and those stewards' departments.
/// The People page's All stewards scope lists it; a steward scope offers the rest of it under
/// "Not with this steward".
struct PeopleRoster: Hashable, Sendable {
    struct Person: Hashable, Sendable, Identifiable {
        var id: String
        var name: String
        var role: String?
        /// Steward ids, in the order given.
        var stewards: [String]
        var departments: [String]
        /// How the first steward reaches them, for the add form.
        var first: PeopleDirectory.Person
        var approves: [String]
        /// Messages in and out across their stewards, from the same thread fold the
        /// inspector counts (reports left out).
        var inbound: Int
        var outbound: Int
    }

    var people: [Person]

    /// Each person's stewards come most-talked first, so Message and the inspector open the
    /// thread that has their messages.
    init(
        events: [FeatureEvent], stewards: [String],
        conversations: [String: [FeatureConversationEntry]] = [:]
    ) {
        var byID: [String: Person] = [:]
        var talk: [String: Int] = [:]
        var order: [String] = []
        for steward in stewards {
            let directory = PeopleDirectory(events: events, steward: steward)
            let department = directory.live?.charter["department"]?.string
            for person in directory.people {
                if byID[person.id] == nil {
                    order.append(person.id)
                    byID[person.id] = Person(
                        id: person.id, name: person.name, role: person.role, stewards: [],
                        departments: [], first: person, approves: [], inbound: 0, outbound: 0)
                }
                byID[person.id]?.stewards.append(steward)
                if let department, byID[person.id]?.departments.contains(department) == false {
                    byID[person.id]?.departments.append(department)
                }
                for kind in person.approves where byID[person.id]?.approves.contains(kind) == false
                {
                    byID[person.id]?.approves.append(kind)
                }
                let tally = PeopleThreadText.tally(
                    PeopleThread(
                        events: events, steward: steward, person: person.id,
                        conversation: conversations["\(steward)/\(person.id)"]))
                byID[person.id]?.inbound += tally.inbound
                byID[person.id]?.outbound += tally.outbound
                talk["\(steward)/\(person.id)"] = tally.inbound + tally.outbound
                if byID[person.id]?.role == nil { byID[person.id]?.role = person.role }
            }
        }
        people = order.compactMap { id in
            guard var person = byID[id] else { return nil }
            let rank = Dictionary(
                uniqueKeysWithValues: person.stewards.enumerated().map { ($1, $0) })
            person.stewards.sort { a, b in
                let (ta, tb) = (talk["\(a)/\(id)"] ?? 0, talk["\(b)/\(id)"] ?? 0)
                return ta != tb ? ta > tb : rank[a, default: 0] < rank[b, default: 0]
            }
            if let first = person.stewards.first,
                let known = PeopleDirectory(events: events, steward: first).people
                    .first(where: { $0.id == id })
            {
                person.first = known
            }
            return person
        }
    }

    /// People some other steward works with but `steward` does not.
    func notWith(_ steward: String) -> [Person] {
        people.filter { !$0.stewards.contains(steward) }
    }
}

enum PeopleText {
    /// "approves reply, refund" or "approves any action"; nil for someone who approves nothing,
    /// so rows and the inspector say nothing about it.
    static func approves(_ kinds: [String], prefix: String = "approves ") -> String? {
        guard !kinds.isEmpty else { return nil }
        return prefix
            + kinds.map { $0 == "*" ? "any action" : ActionWords.kind($0) }
            .joined(separator: ", ")
    }
}

enum RosterText {
    /// "Support triage, Refunds +2": the first two names, then how many more.
    static func names(_ names: [String], shown: Int = 2) -> String {
        guard !names.isEmpty else { return "no steward" }
        let head = names.prefix(shown).joined(separator: ", ")
        return names.count > shown ? head + " +\(names.count - shown)" : head
    }
}
