import Foundation

/// The tabs of a steward's main pane, in STYLE.md order.
enum StewardTab: String, CaseIterable, Identifiable, Sendable {
    case overview, stream, changes, ledger, memory, routines, rehearsals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .stream: "Stream"
        case .changes: "Changes"
        case .ledger: "Ledger"
        case .memory: "Memory"
        case .routines: "Routines"
        case .rehearsals: "Rehearsals"
        }
    }
}

/// What the main pane shows.
enum Destination: Hashable, Sendable {
    /// A steward's pane with its header and tabs.
    case steward(String)
    /// The approval queue across all stewards.
    case approvals
}

/// Where the person is in the app. Selection rules live here so they are testable.
struct NavigationState: Hashable, Sendable {
    var destination: Destination?
    /// The run selected in the rail, within the selected steward.
    var run: String?
    /// Overview is the default: every steward opens on its metric, plan, and activity.
    var tab: StewardTab = .overview

    /// The selected steward id, if a steward pane is showing.
    var steward: String? {
        if case .steward(let id) = destination { return id }
        return nil
    }

    /// Selects a steward. Another steward opens on its Overview tab with no run; the same
    /// steward keeps its tab and run.
    mutating func select(steward id: String) {
        if steward != id {
            run = nil
            tab = .overview
        }
        destination = .steward(id)
    }

    /// Selects a run under its steward and shows its stream.
    mutating func select(run id: String, steward stewardID: String) {
        destination = .steward(stewardID)
        run = id
        tab = .stream
    }

    mutating func showApprovals() {
        destination = .approvals
        run = nil
    }

    /// Keeps the selection valid after the steward list changes: a vanished steward falls back
    /// to the first one, and an empty list clears the selection.
    mutating func reconcile(stewards ids: [String], runs runIDs: [String]) {
        if destination == .approvals { return }
        guard let current = steward, ids.contains(current) else {
            destination = ids.first.map(Destination.steward)
            run = nil
            return
        }
        if let run, !runIDs.contains(run) { self.run = nil }
    }
}
