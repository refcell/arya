import AryaCore
import AryaLedger
import Foundation

extension MemoryAddedPayload: EventPayload {
    public static let type = EventType.memoryAdded
}

extension MemoryRetractedPayload: EventPayload {
    public static let type = EventType.memoryRetracted
}

extension RoutineProposedPayload: EventPayload {
    public static let type = EventType.routineProposed
}

extension RoutinePromotedPayload: EventPayload {
    public static let type = EventType.routinePromoted
}

extension RoutineRetiredPayload: EventPayload {
    public static let type = EventType.routineRetired
}

extension MemoryAuthor {
    /// The ledger actor of an event this author records.
    public var actor: Actor {
        Actor(kind: Actor.Kind(rawValue: kind.rawValue) ?? .system, id: id)
    }
}

extension MemoryEventRecord {
    /// The record the projections read from a ledger event. Memory events are small, so the
    /// payload is re-encoded canonically; the hash chain is not involved.
    public init(_ event: Event) throws {
        self.init(
            seq: Int(event.seq), id: event.id, steward: event.steward, run: event.run,
            type: event.type.rawValue, payload: try CanonicalJSON.encode(event.payload))
    }
}

extension MemoryProjection {
    /// Applies a ledger event; events outside `memory.*` are skipped without decoding.
    public mutating func apply(_ event: Event) throws {
        guard event.type.namespace == "memory" else {
            lastSeqFloor(Int(event.seq))
            return
        }
        try apply(MemoryEventRecord(event))
    }

    /// Builds the projection from ledger events in order.
    public init(ledger events: some Sequence<Event>) throws {
        self.init()
        for event in events { try apply(event) }
    }
}

extension RoutineLibrary {
    /// Applies a ledger event; events outside `routine.*` are skipped without decoding.
    public mutating func apply(_ event: Event) throws {
        guard event.type.namespace == "routine" else {
            lastSeqFloor(Int(event.seq))
            return
        }
        try apply(MemoryEventRecord(event))
    }

    /// Builds the library from ledger events in order.
    public init(ledger events: some Sequence<Event>) throws {
        self.init()
        for event in events { try apply(event) }
    }
}

extension EventDraft {
    /// The `memory.added` draft for a note, attributed to its author.
    public static func memoryAdded(_ note: MemoryNote, steward: StewardID) throws -> EventDraft {
        try EventDraft(
            MemoryAddedPayload(note: note), actor: note.provenance.author.actor,
            steward: steward, run: note.provenance.run)
    }

    /// The `memory.retracted` draft; `actor` is whoever retracts the note.
    public static func memoryRetracted(
        _ note: NoteID, steward: StewardID, actor: Actor, reason: String? = nil
    ) throws -> EventDraft {
        try EventDraft(
            MemoryRetractedPayload(note: note, reason: reason), actor: actor, steward: steward)
    }
}
