import AryaCore
import AryaLedger

/// A runtime projection (`StewardBook`, `RunBook`, `ApprovalBook`) that the real ledger can
/// keep in its projection cache (decision 0028). Folding ledger events through `apply(_:)`
/// is exactly the runtime fold: each event becomes the same `RuntimeEvent` the sink returns.
public protocol RuntimeBook: LedgerProjection, Codable {
    /// The cache file name under `cache/`. Bump its version suffix whenever the fold or the
    /// coded shape changes, so a cache written by older code is never trusted.
    static var cacheName: String { get }
    /// Folds a whole event list, oldest first.
    init(_ events: [RuntimeEvent]) throws
    /// Folds one runtime event.
    mutating func apply(_ event: RuntimeEvent) throws
}

extension RuntimeBook {
    /// Folds one ledger event as the runtime sees it.
    public mutating func apply(_ event: Event) throws {
        try apply(RuntimeEvent(event))
    }
}

extension EventSink {
    /// The book for every event so far. Over the real ledger it loads `cache/<name>.json`,
    /// folds only the events appended since, and saves the result; over any other sink it
    /// folds every event.
    public func book<B: RuntimeBook>(_ type: B.Type) async throws -> B {
        if let ledger = self as? LedgerEventSink {
            return try ProjectionCache(home: ledger.store.home).current(B.self, name: B.cacheName)
                .value
        }
        return try B(try await events(from: 1))
    }
}
