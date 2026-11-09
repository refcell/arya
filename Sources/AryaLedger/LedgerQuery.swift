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

    public init(
        steward: StewardID? = nil, run: RunID? = nil, types: Set<EventType> = [],
        namespaces: Set<String> = [], actorKind: Actor.Kind? = nil, actorID: String? = nil
    ) {
        self.steward = steward
        self.run = run
        self.types = types
        self.namespaces = namespaces
        self.actorKind = actorKind
        self.actorID = actorID
    }

    public func matches(_ event: Event) -> Bool {
        if let steward, event.steward != steward { return false }
        if let run, event.run != run { return false }
        if !types.isEmpty, !types.contains(event.type) { return false }
        if !namespaces.isEmpty, !namespaces.contains(String(event.type.namespace)) { return false }
        if let actorKind, event.actor.kind != actorKind { return false }
        if let actorID, event.actor.id != actorID { return false }
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
    /// Up to `limit` matching events with `seq > after`, oldest first.
    public func page(_ filter: LedgerFilter = LedgerFilter(), after: Int64 = 0, limit: Int = 100)
        throws -> LedgerPage
    {
        let limit = max(1, limit)
        var events: [Event] = []
        var more = false
        do {
            try forEach(from: after + 1) { event in
                guard filter.matches(event) else { return }
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
    /// `seq` order. For a table that opens at the newest events and scrolls back.
    public func pageBackward(
        _ filter: LedgerFilter = LedgerFilter(), before: Int64? = nil, limit: Int = 100
    ) throws -> LedgerPage {
        let limit = max(1, limit)
        var window: [Event] = []
        var dropped = false
        try forEach { event in
            if let before, event.seq >= before { return }
            guard filter.matches(event) else { return }
            window.append(event)
            if window.count > limit {
                window.removeFirst()
                dropped = true
            }
        }
        return LedgerPage(events: window, next: dropped ? window.first?.seq : nil)
    }
}

private struct StopScan: Error {}
