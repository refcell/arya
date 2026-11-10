import Foundation

/// The ways a steward and its people talk: the local inbox and each relay connection people are
/// reached through, with who uses it, the week's volume, and the last message. Built from the
/// directory and each person's thread, so it counts what People shows.
struct PeopleChannels: Hashable, Sendable {
    struct Channel: Hashable, Sendable, Identifiable {
        /// `inbox`, or the relay connection's id.
        var id: String
        var relay: Bool
        /// Whether the live charter still binds the relay (always true for the inbox).
        var bound: Bool
        var people: [String]
        /// Messages in and out per day for the last 7 days, oldest first.
        var daily: [Double]
        var inbound: Int
        var outbound: Int
        var last: Last?
    }

    struct Last: Hashable, Sendable {
        var at: Date
        /// The person's name, or nil for the steward.
        var from: String?
        var text: String
    }

    var channels: [Channel]

    init(events: [FeatureEvent], steward: String, now: Date) {
        let directory = PeopleDirectory(events: events, steward: steward)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var byID: [String: Channel] = [:]
        var order: [String] = ["inbox"]
        byID["inbox"] = Channel(
            id: "inbox", relay: false, bound: true, people: [],
            daily: Array(repeating: 0, count: 7),
            inbound: 0, outbound: 0)
        for relay in directory.relays where byID[relay] == nil {
            // A connection is a channel only once someone is reached through it.
            guard directory.people.contains(where: { $0.via == relay }) else { continue }
            order.append(relay)
            byID[relay] = Channel(
                id: relay, relay: true, bound: true, people: [],
                daily: Array(repeating: 0, count: 7),
                inbound: 0, outbound: 0)
        }
        for person in directory.people {
            let id = person.via ?? "inbox"
            if byID[id] == nil {
                order.append(id)
                byID[id] = Channel(
                    id: id, relay: true, bound: false, people: [],
                    daily: Array(repeating: 0, count: 7), inbound: 0, outbound: 0)
            }
            byID[id]?.people.append(person.name)
            let thread = PeopleThread(events: events, steward: steward, person: person.id)
            for entry in thread.entries {
                let day =
                    calendar.dateComponents(
                        [.day], from: calendar.startOfDay(for: entry.at), to: today
                    ).day ?? 7
                guard day >= 0, day < 7 else { continue }
                byID[id]?.daily[6 - day] += 1
                if entry.inbound { byID[id]?.inbound += 1 } else { byID[id]?.outbound += 1 }
            }
            if let entry = thread.entries.last, entry.at > (byID[id]?.last?.at ?? .distantPast) {
                byID[id]?.last = Last(
                    at: entry.at, from: entry.inbound ? person.name : nil, text: entry.text)
            }
        }
        channels = order.compactMap { byID[$0] }
    }
}
