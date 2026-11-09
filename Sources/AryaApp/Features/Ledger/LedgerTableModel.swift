import Foundation

/// The ledger table's filters. A nil field matches everything.
struct LedgerFilter: Hashable, Sendable {
    var steward: String?
    var run: String?
    /// An exact type (`run.decision`) or a namespace ending in a dot (`approval.`).
    var type: String?
    /// An actor as `kind:id` (`human:local`).
    var actor: String?

    static let all = LedgerFilter()

    func matches(_ event: FeatureEvent) -> Bool {
        if let steward, event.steward != steward { return false }
        if let run, event.run != run { return false }
        if let type {
            if type.hasSuffix(".") {
                if !event.type.hasPrefix(type) { return false }
            } else if event.type != type {
                return false
            }
        }
        if let actor, LedgerTable.actorLabel(event.actor) != actor { return false }
        return true
    }

    /// Whether any filter is set.
    var isActive: Bool { self != .all }
}

/// The ledger as a table: the rows that pass the filter, newest first, and the values each
/// filter can take.
struct LedgerTable: Hashable, Sendable {
    var rows: [FeatureEvent]
    var total: Int
    var stewards: [String]
    var runs: [String]
    var namespaces: [String]
    var actors: [String]

    static func build(events: [FeatureEvent], filter: LedgerFilter) -> LedgerTable {
        let scoped = events.filter { filter.steward == nil || $0.steward == filter.steward }
        return LedgerTable(
            rows: events.filter(filter.matches).reversed(),
            total: events.count,
            stewards: distinct(events.compactMap(\.steward)),
            runs: distinct(scoped.compactMap(\.run)),
            namespaces: distinct(events.map(namespace)),
            actors: distinct(events.map { actorLabel($0.actor) }))
    }

    /// `kind:id`, for example `human:local`.
    static func actorLabel(_ actor: FeatureActor) -> String { "\(actor.kind.rawValue):\(actor.id)" }

    /// The type's namespace with its dot: `run.` for `run.tool.call`.
    static func namespace(_ event: FeatureEvent) -> String {
        guard let dot = event.type.firstIndex(of: ".") else { return event.type }
        return String(event.type[...dot])
    }

    private static func distinct(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

/// Text for the ledger view, kept apart from layout so it can be tested.
enum LedgerText {
    /// "Showing 3 of 42 events".
    static func count(_ table: LedgerTable) -> String {
        if table.rows.count == table.total { return "\(table.total) events" }
        return "Showing \(table.rows.count) of \(table.total) events"
    }

    /// The verify result as one sentence with the next step on failure.
    static func verify(_ result: FeatureVerifyResult) -> String {
        switch result {
        case .intact(let events):
            return "The ledger is intact: \(events) events, every hash and sequence checked."
        case .broken(let seq, let reason):
            return "The chain breaks at event \(seq): \(reason). "
                + "The ledger is read-only until you review it."
        }
    }

    /// The fields of an event's detail pane, in display order.
    static func detail(_ event: FeatureEvent) -> [(label: String, value: String)] {
        [
            ("seq", String(event.seq)), ("id", event.id), ("at", FeatureTime.absolute(event.at)),
            ("type", event.type), ("steward", event.steward ?? "—"), ("run", event.run ?? "—"),
            ("actor", LedgerTable.actorLabel(event.actor)),
            ("hash", event.hash.isEmpty ? "—" : event.hash),
        ]
    }
}
