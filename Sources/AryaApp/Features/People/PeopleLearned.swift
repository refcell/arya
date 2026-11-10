import Foundation

/// What stewards learned from one person: the memory notes they authored, from any steward
/// (a correction through the inbox, a case correction, a preference). Notes go to every run of
/// the steward that recorded them, so one person's correction improves that steward for
/// everyone it serves.
struct PeopleLearned: Hashable, Sendable {
    struct Item: Hashable, Sendable, Identifiable {
        var id: String
        var text: String
        var steward: String?
        var at: Date
        /// "correction", "case correction", or "note".
        var source: String
        var live: Bool
    }

    /// Newest first; retracted notes last.
    var items: [Item]

    init(events: [FeatureEvent], person: String) {
        let memory = MemoryList.build(events: events)
        func mine(_ item: MemoryItem) -> Bool {
            item.author.kind == .human && item.author.id == person
        }
        func entry(_ item: MemoryItem) -> Item {
            let source =
                item.caseID != nil
                ? "case correction" : item.tags.contains("correction") ? "correction" : "note"
            return Item(
                id: item.id, text: item.text, steward: item.steward, at: item.addedAt,
                source: source, live: item.isLive)
        }
        items = memory.live.filter(mine).map(entry) + memory.retracted.filter(mine).map(entry)
    }

    var live: [Item] { items.filter(\.live) }
}
