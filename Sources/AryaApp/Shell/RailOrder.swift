import Arya

/// One selectable row in the rail, in reading order.
enum RailItem: Hashable, Sendable {
    case steward(String)
    case run(String, steward: String)
    case approvals
}

/// The rail's rows in reading order and arrow-key movement through them.
enum RailOrder {
    /// The rows the rail shows: every steward, the selected steward's recent runs beneath it,
    /// then the approvals entry. Mirrors `RailView`.
    static func items(
        stewards: [StewardSummary], runs: [String: [RunSummary]], selected: String?,
        runLimit: Int = RailView.runLimit
    ) -> [RailItem] {
        var items: [RailItem] = []
        for steward in stewards {
            items.append(.steward(steward.id))
            if steward.id == selected {
                for run in (runs[steward.id] ?? []).prefix(runLimit) {
                    items.append(.run(run.id, steward: steward.id))
                }
            }
        }
        items.append(.approvals)
        return items
    }

    /// The row currently selected.
    static func current(_ navigation: NavigationState) -> RailItem? {
        switch navigation.destination {
        case .approvals: return .approvals
        case .connections, .people, .portfolio: return nil
        case .steward(let id): return navigation.run.map { .run($0, steward: id) } ?? .steward(id)
        case nil: return nil
        }
    }

    /// The row one step up or down, stopping at the ends.
    static func step(from current: RailItem?, by offset: Int, in items: [RailItem]) -> RailItem? {
        guard !items.isEmpty else { return nil }
        guard let current, let index = items.firstIndex(of: current) else {
            return offset >= 0 ? items.first : items.last
        }
        return items[min(max(index + offset, 0), items.count - 1)]
    }
}

extension NavigationState {
    /// Selects a rail row.
    mutating func select(_ item: RailItem) {
        switch item {
        case .steward(let id): select(steward: id)
        case .run(let id, let steward): select(run: id, steward: steward)
        case .approvals: showApprovals()
        }
    }
}
