import AryaCore

// Run start in O(new events) (decision 0057). A run's instructions need the steward's plan,
// its memory and routines, and what has worked. Folding the whole ledger for them on every
// start made each start cost the home's history. The engine keeps these projections in memory,
// keyed by the last seq it folded, and each start reads only the events appended since. The
// state is a cache of the ledger, never a source of truth: a new engine (a new process) folds
// once, and a sink whose head went backwards (another home) refolds from scratch.

/// The projections a run start reads, as of `seq`.
struct StartState: Sendable {
    var seq = 0
    var plans = PlanBook()
    var memory = MemoryView()
    var findings = FindingBook()
    var effects = EffectFold()

    mutating func apply(_ event: RuntimeEvent) throws {
        try plans.apply(event)
        try memory.apply(event)
        try findings.apply(event)
        effects.apply(event)
        seq = event.seq
    }
}

/// The engine's start state, caught up on each read. Shared by every copy of the engine.
actor StartCache {
    private var state = StartState()
    /// How many events reads have folded in total: a test hook that shows a start reads only
    /// new events.
    private(set) var folded = 0

    /// The state caught up with `sink`.
    func current(_ sink: any EventSink) async throws -> StartState {
        let events = try await sink.events(from: state.seq + 1)
        // Actor reentrancy: another read may have folded some of these while this one waited.
        let fresh = events.filter { $0.seq > state.seq }
        if let first = fresh.first, first.seq != state.seq + 1 {
            // Not a continuation of what was folded (a damaged or different ledger): refold.
            return try await refold(sink)
        }
        for event in fresh { try state.apply(event) }
        folded += fresh.count
        return state
    }

    private func refold(_ sink: any EventSink) async throws -> StartState {
        var fresh = StartState()
        let events = try await sink.events(from: 1)
        for event in events { try fresh.apply(event) }
        folded += events.count
        state = fresh
        return state
    }
}
