import Foundation

/// A question a run addressed to a person binding, with its answer once given.
struct InboxItem: Hashable, Sendable, Identifiable {
    enum State: Hashable, Sendable {
        case waiting
        case answered(String, by: FeatureActor)
        case declined(String?, by: FeatureActor)
        case expired
    }

    var id: String
    var question: String
    /// The person binding, for example `person:alex`.
    var to: String
    var steward: String?
    var run: String?
    var asked: Date
    var state: State

    var isWaiting: Bool { state == .waiting }
}

/// Questions to person bindings, grouped by person: waiting first, then newest first.
struct InboxList: Hashable, Sendable {
    var items: [InboxItem]

    var waiting: Int { items.filter(\.isWaiting).count }

    /// People with questions, in name order.
    var people: [String] { Array(Set(items.map(\.to))).sorted() }

    func items(for person: String) -> [InboxItem] {
        items.filter { $0.to == person }
    }

    /// Questions whose `to` names a person binding (`person:…`). Questions to the local user
    /// stay in the approval queue.
    static func build(events: [FeatureEvent]) -> InboxList {
        var items: [InboxItem] = []
        var index: [String: Int] = [:]
        for event in events {
            let p = event.payload
            switch event.type {
            case "approval.requested":
                guard p["kind"]?.string == "question", let id = p["approval"]?.string,
                    let to = p["to"]?.string, to.hasPrefix("person:")
                else { continue }
                index[id] = items.count
                items.append(
                    InboxItem(
                        id: id, question: p["question"]?.string ?? "", to: to,
                        steward: event.steward, run: event.run, asked: event.at, state: .waiting))
            case "approval.granted", "approval.denied", "approval.expired":
                guard let id = p["approval"]?.string, let at = index[id] else { continue }
                let note = p["note"]?.string
                switch event.type {
                case "approval.granted": items[at].state = .answered(note ?? "", by: event.actor)
                case "approval.denied": items[at].state = .declined(note, by: event.actor)
                default: items[at].state = .expired
                }
            default: continue
            }
        }
        items.sort { lhs, rhs in
            lhs.isWaiting != rhs.isWaiting ? lhs.isWaiting : lhs.asked > rhs.asked
        }
        return InboxList(items: items)
    }
}

/// Text for the inbox, kept apart from layout so it can be tested.
enum InboxText {
    /// "Alex · 2 waiting".
    static func person(_ id: String, waiting: Int) -> String {
        let name = id.hasPrefix("person:") ? String(id.dropFirst("person:".count)) : id
        let shown = name.prefix(1).uppercased() + name.dropFirst()
        return waiting == 0 ? shown : "\(shown) · \(waiting) waiting"
    }

    static func state(_ state: InboxItem.State) -> String {
        switch state {
        case .waiting: return "Waiting for an answer"
        case .answered(let text, let actor): return "Answered by \(actor.id): \(text)"
        case .declined(let note, let actor):
            return "Declined by \(actor.id)" + (note.map { ": \($0)" } ?? "")
        case .expired: return "Expired without an answer"
        }
    }
}
