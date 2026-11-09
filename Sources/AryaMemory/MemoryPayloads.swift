/// Ledger event types owned by the memory module.
public enum MemoryEventType {
    public static let added = "memory.added"
    public static let retracted = "memory.retracted"
}

/// Payload of `memory.added`. The steward that owns the note is the event envelope's `steward`.
public struct MemoryAddedPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var note: MemoryNote

    public init(note: MemoryNote) {
        self.v = 1
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case note
    }
}

/// Payload of `memory.retracted`: hides a note from future runs. The note stays in the ledger.
public struct MemoryRetractedPayload: Codable, Sendable, Equatable {
    public var v: Int
    public var note: String
    public var reason: String?

    public init(note: String, reason: String? = nil) {
        self.v = 1
        self.note = note
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case note
        case reason
    }
}
