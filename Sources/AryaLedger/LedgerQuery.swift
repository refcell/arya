import AryaCore

/// A filter for the app's ledger table and `arya ledger`. Every set field must match; nil
/// matches anything.
public struct LedgerFilter: Hashable, Sendable {
    public var steward: StewardID?
    public var run: RunID?
    /// Exact types. Empty matches every type.
    public var types: Set<EventType>
    /// Type namespaces such as `run` or `approval`. Empty matches every namespace.
    public var namespaces: Set<String>
    public var actorKind: Actor.Kind?
    public var actorID: String?
    /// Events at or after this time.
    public var since: Timestamp?
    /// Events strictly before this time.
    public var until: Timestamp?

    public init(
        steward: StewardID? = nil, run: RunID? = nil, types: Set<EventType> = [],
        namespaces: Set<String> = [], actorKind: Actor.Kind? = nil, actorID: String? = nil,
        since: Timestamp? = nil, until: Timestamp? = nil
    ) {
        self.steward = steward
        self.run = run
        self.types = types
        self.namespaces = namespaces
        self.actorKind = actorKind
        self.actorID = actorID
        self.since = since
        self.until = until
    }

    public func matches(_ event: Event) -> Bool {
        if let steward, event.steward != steward { return false }
        if let run, event.run != run { return false }
        if !types.isEmpty, !types.contains(event.type) { return false }
        if !namespaces.isEmpty, !namespaces.contains(String(event.type.namespace)) { return false }
        if let actorKind, event.actor.kind != actorKind { return false }
        if let actorID, event.actor.id != actorID { return false }
        if let since, event.at < since { return false }
        if let until, event.at >= until { return false }
        return true
    }
}

/// One page of matching events, in `seq` order.
public struct LedgerPage: Hashable, Sendable {
    public var events: [Event]
    /// Pass as `after` (forward) or `before` (backward) to get the next page; nil at the end.
    public var next: Int64?
}

extension LedgerReader {
    /// Up to `limit` matching events with `seq > after`, oldest first. With `index`, a run or
    /// steward query starts at that run's or steward's first event instead of the ledger's
    /// (any staleness is safe: the index only moves the start, never the end).
    public func page(
        _ filter: LedgerFilter = LedgerFilter(), after: Int64 = 0, limit: Int = 100,
        index: Projected<LedgerIndex>? = nil
    ) throws -> LedgerPage {
        let after = max(after, (index.map { start(filter, $0) } ?? 1) - 1)
        let limit = max(1, limit)
        var events: [Event] = []
        var more = false
        do {
            try forEach(filter, from: after + 1) { event in
                if events.count == limit {
                    more = true
                    throw StopScan()
                }
                events.append(event)
            }
        } catch is StopScan {}
        return LedgerPage(events: events, next: more ? events.last?.seq : nil)
    }

    /// Up to `limit` matching events with `seq < before` (the newest when nil), returned in
    /// `seq` order. For a table that opens at the newest events and scrolls back. Reads
    /// newest to oldest (`newest(_:before:limit:)`); `index` is accepted for symmetry with
    /// `page` and not needed.
    public func pageBackward(
        _ filter: LedgerFilter = LedgerFilter(), before: Int64? = nil, limit: Int = 100,
        index: Projected<LedgerIndex>? = nil
    ) throws -> LedgerPage {
        _ = index  // Newest-first reads stop early; the index cannot narrow them further.
        var window = try newest(filter, before: before, limit: limit + 1)
        let dropped = window.count > limit
        if dropped { window.removeFirst() }
        return LedgerPage(events: window, next: dropped ? window.first?.seq : nil)
    }
}

extension LedgerReader {
    /// Every event matching `filter`, starting where `index` says the first can be.
    public func events(_ filter: LedgerFilter, index: Projected<LedgerIndex>) throws -> [Event] {
        try events(filter, from: start(filter, index))
    }

    func start(_ filter: LedgerFilter, _ index: Projected<LedgerIndex>) -> Int64 {
        index.value.firstPossibleSeq(filter, coveredSeq: index.seq)
    }
}

private struct StopScan: Error {}

/// An event with its decoded payload.
public struct TypedEvent<P: EventPayload>: Equatable, Sendable {
    public var event: Event
    public var payload: P

    public init(event: Event, payload: P) {
        self.event = event
        self.payload = payload
    }
}

extension LedgerReader {
    /// Every event of payload type `P` matching `filter` with `seq >= from`, decoded. Lines
    /// of other types are skipped before they are hashed or parsed, so a typed read over
    /// weeks of history costs little more than finding its matches.
    public func events<P: EventPayload>(
        _ type: P.Type, matching filter: LedgerFilter = LedgerFilter(), from seq: Int64 = 1
    ) throws -> [TypedEvent<P>] {
        if !filter.types.isEmpty, !filter.types.contains(P.type) { return [] }
        var typed = filter
        typed.types = [P.type]
        var out: [TypedEvent<P>] = []
        try forEach(typed, from: seq) { event in
            out.append(TypedEvent(event: event, payload: try event.payload(as: P.self)))
        }
        return out
    }
}
