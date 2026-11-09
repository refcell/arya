import AryaCore
import Foundation

/// The slice of a ledger event the memory projections read. A stand-in until `AryaLedger`
/// publishes its `Event` envelope; the envelope will convert to this type.
public struct MemoryEventRecord: Sendable, Equatable {
    public var seq: Int
    public var id: EventID
    public var steward: StewardID?
    public var run: RunID?
    public var type: String
    /// The event's `payload` object as JSON bytes.
    public var payload: Data

    public init(
        seq: Int, id: EventID, steward: StewardID?, run: RunID? = nil, type: String,
        payload: Data
    ) {
        self.seq = seq
        self.id = id
        self.steward = steward
        self.run = run
        self.type = type
        self.payload = payload
    }
}

/// Reasons the memory projection rejects an event.
public enum MemoryProjectionError: Error, Equatable, Sendable {
    case missingSteward(seq: Int)
    case invalidPayload(seq: Int, type: String)
}
