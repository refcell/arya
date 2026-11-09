import Foundation

/// A note that is live (added and not retracted), with the ledger `seq` that added it.
public struct LiveNote: Sendable, Equatable, Hashable {
    public var steward: String
    public var seq: Int
    public var note: MemoryNote

    public init(steward: String, seq: Int, note: MemoryNote) {
        self.steward = steward
        self.seq = seq
        self.note = note
    }
}

/// Live memory notes per steward, projected from `memory.*` events in ledger order. Other event
/// types are ignored, so the projection can be fed the whole ledger.
public struct MemoryProjection: Sendable, Equatable {
    /// Live notes keyed by steward, then by note id.
    private var live: [String: [String: LiveNote]] = [:]
    /// Every note id ever added per steward, so a retracted id is never revived.
    private var seen: [String: Set<String>] = [:]
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
            guard seen[steward, default: []].insert(id).inserted else { return }
            live[steward, default: [:]][id] = LiveNote(
                steward: steward, seq: event.seq, note: payload.note)
        case MemoryEventType.retracted:
            let steward = try requireSteward(event)
            let payload: MemoryRetractedPayload = try decode(event)
            live[steward]?[payload.note] = nil
        default:
            return
        }
    }

    /// Live notes of a steward, oldest first.
    public func liveNotes(steward: String) -> [LiveNote] {
        (live[steward] ?? [:]).values.sorted { $0.seq < $1.seq }
    }

    /// The live note with this id, if any.
    public func note(steward: String, id: String) -> LiveNote? {
        live[steward]?[id]
    }

    /// Stewards with at least one live note, sorted.
    public var stewards: [String] {
        live.filter { !$0.value.isEmpty }.keys.sorted()
    }

    private func requireSteward(_ event: MemoryEventRecord) throws(MemoryProjectionError)
        -> String
    {
        guard let steward = event.steward, !steward.isEmpty else {
            throw .missingSteward(seq: event.seq)
        }
        return steward
    }

    private func decode<T: Decodable>(_ event: MemoryEventRecord) throws(MemoryProjectionError)
        -> T
    {
        do {
            return try JSONDecoder().decode(T.self, from: event.payload)
        } catch {
            throw .invalidPayload(seq: event.seq, type: event.type)
        }
    }
}
