import AryaCore
import Foundation

// The runtime's seam to the ledger. Everything the runtime does is an appended event, and all
// of its state is a projection of those events (ARCHITECTURE.md "Goals"). Until `AryaLedger`
// lands this protocol has only an in-memory double; then a conformance over the ledger store
// replaces it and the envelope types below are deleted in favor of the ledger's.

/// Who caused an event: kind `human`, `steward`, `adapter`, or `system`, and an id.
public struct RuntimeActor: Sendable, Hashable, Codable {
    /// The actor kind.
    public var kind: String
    /// `local` for the local user, a contact id, a steward id, or `arya`.
    public var id: String

    /// Creates an actor.
    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }

    /// The local user.
    public static let localUser = RuntimeActor(kind: "human", id: "local")
    /// The runtime itself.
    public static let system = RuntimeActor(kind: "system", id: "arya")

    /// A person: `local` or a contact id such as `person:alex`.
    public static func person(_ id: String) -> RuntimeActor { RuntimeActor(kind: "human", id: id) }
    /// A steward acting through a run.
    public static func steward(_ id: StewardID) -> RuntimeActor {
        RuntimeActor(kind: "steward", id: id.rawValue)
    }
    /// The adapter process of a run.
    public static func adapter(_ run: RunID) -> RuntimeActor {
        RuntimeActor(kind: "adapter", id: run.rawValue)
    }
}

/// An event before the sink assigns `seq`, `id`, and `at`.
public struct RuntimeEventDraft: Sendable, Hashable {
    /// Event type, for example `approval.requested`.
    public var type: String
    /// Steward, if any.
    public var steward: StewardID?
    /// Run, if any.
    public var run: RunID?
    /// Who caused it.
    public var actor: RuntimeActor
    /// Typed payload as JSON.
    public var payload: JSONValue

    /// Creates a draft.
    public init(
        type: String, steward: StewardID? = nil, run: RunID? = nil, actor: RuntimeActor,
        payload: JSONValue = [:]
    ) {
        self.type = type
        self.steward = steward
        self.run = run
        self.actor = actor
        self.payload = payload
    }
}

/// An appended event.
public struct RuntimeEvent: Sendable, Hashable {
    /// Position from 1, without gaps.
    public var seq: Int
    /// Event id.
    public var id: EventID
    /// Ambient time of the append.
    public var at: Timestamp
    /// The draft it was made from.
    public var draft: RuntimeEventDraft

    /// Creates an event.
    public init(seq: Int, id: EventID, at: Timestamp, draft: RuntimeEventDraft) {
        self.seq = seq
        self.id = id
        self.at = at
        self.draft = draft
    }

    /// Event type.
    public var type: String { draft.type }
    /// Payload.
    public var payload: JSONValue { draft.payload }
}

/// Appends events and reads them back in order.
public protocol EventSink: Sendable {
    /// Appends one event and returns it with `seq`, `id`, and `at` assigned.
    func append(_ draft: RuntimeEventDraft) async throws -> RuntimeEvent
    /// Events with `seq >= from`, in order.
    func events(from seq: Int) async throws -> [RuntimeEvent]
}

/// An in-memory sink for tests; ids and times come from its ambient.
public actor MemoryEventSink: EventSink {
    private let ambient: Ambient
    private var stored: [RuntimeEvent] = []

    /// Creates an empty sink.
    public init(ambient: Ambient) {
        self.ambient = ambient
    }

    public func append(_ draft: RuntimeEventDraft) async throws -> RuntimeEvent {
        let event = RuntimeEvent(
            seq: stored.count + 1, id: ambient.newID(EventID.self), at: ambient.now(),
            draft: draft)
        stored.append(event)
        return event
    }

    public func events(from seq: Int) async throws -> [RuntimeEvent] {
        stored.filter { $0.seq >= seq }
    }
}

/// Encoding helpers between payload structs and `JSONValue`.
enum Payload {
    static func encode(_ value: some Encodable) throws -> JSONValue {
        try CanonicalJSON.jsonValue(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue) throws -> T {
        try CanonicalJSON.decode(type, from: try CanonicalJSON.encode(value))
    }
}
