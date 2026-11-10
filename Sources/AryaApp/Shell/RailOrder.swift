import Arya

/// One selectable row in the rail, in reading order.
enum RailItem: Hashable, Sendable {
    case steward(String)
    case run(String, steward: String)
    case approvals
}

/// Stewards grouped by department for the sidebar.
struct RailGroup: Equatable, Identifiable {
    /// The department; nil when no steward has one (the rail shows one flat list).
    var department: String?
    var stewards: [StewardSummary]
    var id: String { department ?? "" }

    /// The label for stewards without a department when others have one.
    static let unassigned = "Unassigned"

    /// `sorted` (need first) split by department: groups alphabetical, `Unassigned` last, each
    /// keeping the need order. One nil group when `departments` names none of them.
    static func build(sorted: [StewardSummary], departments: [String: String]) -> [RailGroup] {
        guard sorted.contains(where: { departments[$0.id] != nil }) else {
            return sorted.isEmpty ? [] : [RailGroup(department: nil, stewards: sorted)]
        }
        let grouped = Dictionary(grouping: sorted) { departments[$0.id] ?? unassigned }
        let names = grouped.keys.sorted {
            ($0 == unassigned ? 1 : 0, $0) < ($1 == unassigned ? 1 : 0, $1)
        }
        return names.map { RailGroup(department: $0, stewards: grouped[$0] ?? []) }
    }

    /// The stewards the rail shows, in order, skipping folded groups.
    static func visible(_ groups: [RailGroup], collapsed: Set<String>) -> [StewardSummary] {
        groups.filter { $0.department.map { !collapsed.contains($0) } ?? true }
            .flatMap(\.stewards)
    }
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
        case .connections, .people, .portfolio, .routines: return nil
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
