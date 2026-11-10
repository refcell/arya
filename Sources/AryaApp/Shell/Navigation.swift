import Foundation

/// The tabs of a steward's main pane, in STYLE.md order.
enum StewardTab: String, CaseIterable, Identifiable, Sendable {
    /// Plan, recap, and recent activity (the default).
    case overview
    /// Rehearsals, proposals, and charter changes.
    case improve
    /// Memory and routines.
    case knowledge
    case ledger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .improve: "Improve"
        case .knowledge: "Knowledge"
        case .ledger: "Ledger"
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
    var tab: StewardTab = .overview
    /// Whether the right-hand inspector (selection detail, steward context, settings) shows.
    var inspector = true
    /// The ledger event whose inspector is open on the Ledger tab.
    var ledgerEvent: String?

    /// The selected steward id, if a steward pane is showing.
    var steward: String? {
        if case .steward(let id) = destination { return id }
        return nil
    }

    /// Selects a steward. Another steward opens on its Overview tab with no run; the same
    /// steward keeps its tab and run.
    /// Shows a steward's page with no run selected (the breadcrumb's way back).
    mutating func select(steward id: String, showRun run: String?) {
        destination = .steward(id)
        self.run = run
    }

    mutating func select(steward id: String) {
        if steward != id {
            run = nil
            tab = .overview
            ledgerEvent = nil
        }
        destination = .steward(id)
    }

    /// Selects a run under its steward; the page shows its transcript.
    mutating func select(run id: String, steward stewardID: String) {
        destination = .steward(stewardID)
        run = id
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
