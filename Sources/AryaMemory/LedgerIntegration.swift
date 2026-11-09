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

/// A recorded run's memory inputs that do not match the ledger before it started.
public enum MemoryReplayDivergence: Equatable, Sendable {
    /// `run.started.memory` is missing or not a snapshot.
    case unreadableSnapshot
    /// The recorded snapshot names a note that was not live when the run started.
    case noteNotLive(NoteID)
    /// The recorded routine version was not the live version of that name.
    case routineVersion(name: String, recorded: String, live: String?)
    /// A routine was live when the run started but is missing from the record.
    case routineMissing(name: String)
}

/// Checks a run's recorded memory and routine inputs against the ledger before it started.
public enum MemoryReplay {
    /// Rebuilds the projections from the events before `seq` (exclusive).
    public static func state(before seq: Int64, ledger events: some Sequence<Event>) throws
        -> (memory: MemoryProjection, routines: RoutineLibrary)
    {
        var memory = MemoryProjection()
        var routines = RoutineLibrary()
        for event in events where event.seq < seq {
            try memory.apply(event)
            try routines.apply(event)
        }
        return (memory, routines)
    }

    /// Divergences of a `run.started` event's `memory` and `routines` fields from the state
    /// before it. Empty means the run saw exactly what the ledger says was live.
    public static func check(
        runStarted: Event, memory: MemoryJSONField, routines recorded: [String: String],
        state: (memory: MemoryProjection, routines: RoutineLibrary)
    ) -> [MemoryReplayDivergence] {
        guard let steward = runStarted.steward else { return [.unreadableSnapshot] }
        var out: [MemoryReplayDivergence] = []
        switch memory {
        case .absent:
            break
        case .value(let json):
            guard
                let snapshot = try? CanonicalJSON.decode(
                    MemorySnapshot.self, from: CanonicalJSON.encode(json))
            else { return [.unreadableSnapshot] }
            for id in snapshot.notes where state.memory.note(steward: steward, id: id) == nil {
                out.append(.noteNotLive(id))
            }
        }
        let live = state.routines.liveVersions(steward: steward)
        for name in recorded.keys.sorted() where live[name] != recorded[name] {
            out.append(
                .routineVersion(name: name, recorded: recorded[name] ?? "", live: live[name]))
        }
        for name in live.keys.sorted() where recorded[name] == nil {
            out.append(.routineMissing(name: name))
        }
        return out
    }
}

/// The `memory` field of `run.started`, which may be absent.
public enum MemoryJSONField: Equatable, Sendable {
    case absent
    case value(JSONValue)

    public init(_ json: JSONValue?) {
        self = json.map { $0 == .null ? .absent : .value($0) } ?? .absent
    }
}

/// The home's blob store holds routine content: same keys (lowercase hex SHA-256).
extension BlobStore: RoutineBlobStore {
    public func getIfPresent(_ key: String) throws -> Data? {
        do {
            return try get(key)
        } catch BlobError.missing {
            return nil
        } catch BlobError.corrupt {
            throw RoutineContentError.corruptBlob(key)
        }
    }
}
