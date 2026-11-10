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
        var messages: Int
    }

    var people: [Person]

    init(events: [FeatureEvent], stewards: [String]) {
        var byID: [String: Person] = [:]
        var order: [String] = []
        for steward in stewards {
            let directory = PeopleDirectory(events: events, steward: steward)
            let department = directory.live?.charter["department"]?.string
            for person in directory.people {
                if byID[person.id] == nil {
                    order.append(person.id)
                    byID[person.id] = Person(
                        id: person.id, name: person.name, role: person.role, stewards: [],
                        departments: [], first: person, approves: [], messages: 0)
                }
                byID[person.id]?.stewards.append(steward)
                if let department, byID[person.id]?.departments.contains(department) == false {
                    byID[person.id]?.departments.append(department)
                }
                for kind in person.approves where byID[person.id]?.approves.contains(kind) == false
                {
                    byID[person.id]?.approves.append(kind)
                }
                byID[person.id]?.messages += person.messages
                if byID[person.id]?.role == nil { byID[person.id]?.role = person.role }
            }
        }
        people = order.compactMap { byID[$0] }
    }

    /// People some other steward works with but `steward` does not.
    func notWith(_ steward: String) -> [Person] {
        people.filter { !$0.stewards.contains(steward) }
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
