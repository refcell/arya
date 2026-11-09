import AryaCore
import CryptoKit
import Foundation

/// One ledger line: an envelope around a typed payload, chained to the previous event by
/// `prev` and sealed by `hash` (decisions 0003 and 0012).
public struct Event: Hashable, Sendable, Codable {
    /// Envelope schema version; always 1.
    public var v: Int
    /// Position in the ledger, from 1 with no gaps.
    public var seq: Int64
    public var id: EventID
    public var at: Timestamp
    public var steward: StewardID?
    public var run: RunID?
    public var actor: Actor
    public var type: EventType
    /// Always a JSON object. Decode it with `payload(as:)`.
    public var payload: JSONValue
    /// The previous event's `hash`; 64 zeros for the first event.
    public var prev: String
    /// Lowercase hex SHA-256 of the canonical bytes of every other field.
    public var hash: String

    /// `prev` of the first event.
    public static let genesisHash = String(repeating: "0", count: 64)

    private enum CodingKeys: String, CodingKey {
        case v, seq, id, at, steward, run, actor, type, payload, prev, hash
    }

    /// Decodes the payload as `P`. Throws `LedgerError.payloadType` if the event is another
    /// type.
    public func payload<P: EventPayload>(as type: P.Type) throws -> P {
        guard self.type == P.type else {
            throw LedgerError.payloadType(seq: seq, expected: P.type, actual: self.type)
        }
        return try JSONDecoder().decode(P.self, from: CanonicalJSON.encode(payload))
    }
}

/// Who caused an event: the local user or another person (`human`), a steward, an adapter, or
/// arya itself (`system`).
public struct Actor: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, Codable { case human, steward, adapter, system }

    public var kind: Kind
    /// `local` for the local user, a binding contact id such as `person:alex` for others, a
    /// steward id, an adapter profile name, or `arya` for the system.
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// The person at this machine.
    public static let local = Actor(kind: .human, id: "local")
    /// arya itself.
    public static let system = Actor(kind: .system, id: "arya")

    public static func human(_ id: String) -> Actor { Actor(kind: .human, id: id) }
    public static func steward(_ id: StewardID) -> Actor { Actor(kind: .steward, id: id.rawValue) }
    public static func adapter(_ profile: String) -> Actor { Actor(kind: .adapter, id: profile) }

    public var description: String { "\(kind.rawValue):\(id)" }

    private enum CodingKeys: String, CodingKey { case kind, id }
}

/// An event that has not been written yet. The store stamps `id` and `at` from `Ambient` and
/// assigns `seq`, `prev`, and `hash` under the ledger lock.
public struct EventDraft: Hashable, Sendable {
    public var type: EventType
    public var actor: Actor
    public var steward: StewardID?
    public var run: RunID?
    public var payload: JSONValue

    /// A draft with an untyped payload, which must be a JSON object.
    public init(
        type: EventType, actor: Actor, steward: StewardID? = nil, run: RunID? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.type = type
        self.actor = actor
        self.steward = steward
        self.run = run
        self.payload = payload
    }

    /// A draft carrying a typed payload.
    public init<P: EventPayload>(
        _ payload: P, actor: Actor, steward: StewardID? = nil, run: RunID? = nil
    ) throws {
        self.init(
            type: P.type, actor: actor, steward: steward, run: run,
            payload: try CanonicalJSON.jsonValue(payload))
    }
}

/// A typed event payload. Payloads are versioned with their own `"v": 1` field.
public protocol EventPayload: Codable, Sendable, Equatable {
    static var type: EventType { get }
}
