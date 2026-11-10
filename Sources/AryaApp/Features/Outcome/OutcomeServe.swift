import Foundation

/// The workspace's serve status (`Workspace.serveStatus`), the one source for whether triggers
/// fire and when each steward runs next. NOW, the inspector's schedule line, and the status bar
/// all read it through `OutcomeState`, so they never disagree.
struct FeatureServe: Hashable, Sendable {
    /// True while a process fires the home's triggers; nil when the source cannot tell.
    var serving: Bool?
    /// Each steward's next scheduled wake.
    var wakes: [String: Date] = [:]
    /// Each steward's schedule state: off, unscheduled, running, due, or waiting.
    var states: [String: String] = [:]

    /// The ledger's wake corrected by the serve status: paused stays paused, an unscheduled
    /// steward runs on demand, and a scheduled one wakes when the workspace says.
    func wake(_ ledger: OutcomeWake, steward: String) -> OutcomeWake {
        if ledger == .paused { return .paused }
        if states[steward] == "unscheduled" { return .onDemand }
        if let date = wakes[steward] { return .at(date) }
        return ledger
    }
}
