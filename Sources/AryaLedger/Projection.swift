/// State folded from ledger events. Domain projections (stewards, runs, approvals, memory,
/// proposals, rehearsals) live with the module that writes those events (decision 0028);
/// this protocol and `Projected` give them one way to rebuild and catch up.
public protocol LedgerProjection: Sendable {
    /// The state of an empty ledger.
    init()
    /// Folds one event. Unknown event types must be ignored, not rejected.
    mutating func apply(_ event: Event) throws
}

/// A projection and the ledger position it reflects.
public struct Projected<P: LedgerProjection>: Sendable {
    public private(set) var value: P
    /// The last folded `seq` (0 when nothing was folded).
    public private(set) var seq: Int64
    /// The last folded event's `hash` (the genesis hash when nothing was folded).
    public private(set) var hash: String

    /// An empty projection at the start of the ledger.
    public init() {
        value = P()
        seq = 0
        hash = Event.genesisHash
    }

    /// Restores a projection saved at `seq`/`hash`, for example from a cache.
    public init(value: P, seq: Int64, hash: String) {
        self.value = value
        self.seq = seq
        self.hash = hash
    }

    /// Folds `event` if it is the next one. Throws `ProjectionError.discontinuity` otherwise,
    /// so a projection can never silently skip or repeat events.
    public mutating func apply(_ event: Event) throws {
        guard event.seq == seq + 1, event.prev == hash else {
            throw ProjectionError.discontinuity(expectedSeq: seq + 1, found: event.seq)
        }
        try value.apply(event)
        seq = event.seq
        hash = event.hash
    }
}

/// Projection errors.
public enum ProjectionError: Error, Hashable, Sendable {
    /// The next event did not follow the last folded one (wrong `seq` or `prev`).
    case discontinuity(expectedSeq: Int64, found: Int64)
    /// The ledger was compacted and no trusted seed restores this projection; restore
    /// `archive/` to rebuild it.
    case archived(String)
}

extension LedgerReader {
    /// Folds every event into a fresh projection.
    public func rebuild<P: LedgerProjection>(_ type: P.Type = P.self) throws -> Projected<P> {
        var projected = Projected<P>()
        try forEach { try projected.apply($0) }
        return projected
    }

    /// Folds events appended since `projected` was last updated. If the ledger no longer
    /// continues from `projected` (it was replaced, or a cache is stale), rebuilds from
    /// scratch. Returns whether a rebuild happened.
    @discardableResult
    public func catchUp<P: LedgerProjection>(_ projected: inout Projected<P>) throws -> Bool {
        var working = projected
        do {
            try forEach(from: projected.seq + 1) { try working.apply($0) }
        } catch is ProjectionError {
            projected = try rebuild(P.self)
            return true
        }
        if working.seq == projected.seq, projected.seq > 0, try !stillHas(projected) {
            projected = try rebuild(P.self)
            return true
        }
        projected = working
        return false
    }

    /// Whether the event at `projected.seq` still has `projected.hash` (no truncation or
    /// replacement behind the projection's back).
    private func stillHas<P>(_ projected: Projected<P>) throws -> Bool {
        var found = false
        try forEach(from: projected.seq) { event in
            if event.seq == projected.seq { found = event.hash == projected.hash }
        }
        return found
    }
}
