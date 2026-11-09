import AryaCore
import AryaLedger
import Foundation

/// The runtime's `EventSink` over the real hash-chained ledger in a home directory.
///
/// Appends go through `LedgerStore` (per-append `flock`, `fsync`, torn-line repair), so the
/// CLI, the app, and a scheduler process can share one home. Reads go through `LedgerReader`,
/// which checks each line's hash.
public struct LedgerEventSink: EventSink {
    /// The store appends go to.
    public let store: LedgerStore
    private let reader: LedgerReader

    /// Wraps an opened store.
    public init(store: LedgerStore) {
        self.store = store
        reader = LedgerReader(home: store.home)
    }

    /// Opens (creating if needed) the ledger in `home`; ids and times come from `ambient`.
    public init(home: URL, ambient: Ambient) throws {
        self.init(store: try LedgerStore(home: home, ambient: ambient))
    }

    public func append(_ draft: RuntimeEventDraft) async throws -> RuntimeEvent {
        RuntimeEvent(try store.append(draft.ledgerDraft))
    }

    public func events(from seq: Int) async throws -> [RuntimeEvent] {
        try reader.events(from: Int64(max(1, seq))).map(RuntimeEvent.init)
    }
}

extension RuntimeActor {
    /// The ledger form of this actor; an unknown kind is recorded as `system`.
    public var ledgerActor: Actor { Actor(kind: Actor.Kind(rawValue: kind) ?? .system, id: id) }

    /// The runtime form of a ledger actor.
    public init(_ actor: Actor) { self.init(kind: actor.kind.rawValue, id: actor.id) }
}

extension RuntimeEventDraft {
    /// The ledger form of this draft.
    public var ledgerDraft: EventDraft {
        EventDraft(
            type: EventType(type), actor: actor.ledgerActor, steward: steward, run: run,
            payload: payload)
    }
}

extension RuntimeEvent {
    /// The runtime view of a ledger event.
    public init(_ event: Event) {
        self.init(
            seq: Int(event.seq), id: event.id, at: event.at,
            draft: RuntimeEventDraft(
                type: event.type.rawValue, steward: event.steward, run: event.run,
                actor: RuntimeActor(event.actor), payload: event.payload))
    }
}
