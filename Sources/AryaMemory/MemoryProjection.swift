import AryaCore
import Foundation

/// A note that is live (added and not retracted), with the ledger `seq` that added it.
public struct LiveNote: Sendable, Equatable, Hashable {
    public var steward: StewardID
    public var seq: Int
    public var note: MemoryNote

    public init(steward: StewardID, seq: Int, note: MemoryNote) {
        self.steward = steward
        self.seq = seq
        self.note = note
    }
}

/// Live memory notes per steward, projected from `memory.*` events in ledger order. Other event
/// types are ignored, so the projection can be fed the whole ledger.
public struct MemoryProjection: Sendable, Equatable {
    /// Live notes keyed by steward, then by note id.
    private var live: [StewardID: [NoteID: LiveNote]] = [:]
    /// Every note ever added per steward, retracted or not: a retracted id is never revived,
    /// and a recorded snapshot can always be resolved.
    private var added: [StewardID: [NoteID: LiveNote]] = [:]
    /// The last applied ledger `seq`.
    public private(set) var lastSeq = 0

    public init() {}

    /// Builds the projection from events in ledger order.
    public init(events: some Sequence<MemoryEventRecord>) throws(MemoryProjectionError) {
        for event in events { try apply(event) }
    }

    /// Applies one event. Duplicate adds and retractions of unknown notes are no-ops.
    public mutating func apply(_ event: MemoryEventRecord) throws(MemoryProjectionError) {
        lastSeq = max(lastSeq, event.seq)
        switch event.type {
        case MemoryEventType.added:
            let steward = try requireSteward(event)
            let payload: MemoryAddedPayload = try decode(event)
            let id = payload.note.id
            guard added[steward]?[id] == nil else { return }
            let note = LiveNote(steward: steward, seq: event.seq, note: payload.note)
            added[steward, default: [:]][id] = note
            live[steward, default: [:]][id] = note
        case MemoryEventType.retracted:
            let steward = try requireSteward(event)
            let payload: MemoryRetractedPayload = try decode(event)
            live[steward]?[payload.note] = nil
        default:
            return
        }
    }

    /// Records that the ledger reached `seq` without a relevant event.
    mutating func lastSeqFloor(_ seq: Int) {
        lastSeq = max(lastSeq, seq)
    }

    /// Live notes of a steward, oldest first.
    public func liveNotes(steward: StewardID) -> [LiveNote] {
        (live[steward] ?? [:]).values.sorted { $0.seq < $1.seq }
    }

    /// The live note with this id, if any.
    public func note(steward: StewardID, id: NoteID) -> LiveNote? {
        live[steward]?[id]
    }

    /// A note ever added to this steward, even if it was retracted since.
    public func addedNote(steward: StewardID, id: NoteID) -> LiveNote? {
        added[steward]?[id]
    }

    /// Stewards with at least one live note, sorted.
    public var stewards: [StewardID] {
        live.filter { !$0.value.isEmpty }.keys.sorted()
    }

    private func requireSteward(_ event: MemoryEventRecord) throws(MemoryProjectionError)
        -> StewardID
    {
        guard let steward = event.steward else {
            throw .missingSteward(seq: event.seq)
        }
        return steward
    }

    private func decode<T: Decodable>(_ event: MemoryEventRecord) throws(MemoryProjectionError)
        -> T
    {
        do {
            return try CanonicalJSON.decode(T.self, from: event.payload)
        } catch {
            throw .invalidPayload(seq: event.seq, type: event.type)
        }
    }
}
