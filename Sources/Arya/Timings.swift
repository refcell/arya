import Foundation

/// How long one facade call took in this process, summed by name: a debug read for the app's
/// dev overlay and latency budget.
public struct FacadeTiming: Sendable, Hashable, Codable {
    public var name: String
    public var calls: Int
    public var totalMillis: Double
    public var meanMillis: Double
    public var maxMillis: Double
    public var lastMillis: Double
}

/// Process-wide call timings. Names are bounded so a caller cannot grow it without limit.
final class FacadeTimings: @unchecked Sendable {
    static let shared = FacadeTimings()
    static let maxNames = 256

    private let lock = NSLock()
    private var entries: [String: FacadeTiming] = [:]

    func record(_ name: String, _ duration: Duration) {
        let millis =
            Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        lock.withLock {
            var entry =
                entries[name]
                ?? FacadeTiming(
                    name: name, calls: 0, totalMillis: 0, meanMillis: 0, maxMillis: 0,
                    lastMillis: 0)
            guard entries[name] != nil || entries.count < Self.maxNames else { return }
            entry.calls += 1
            entry.totalMillis += millis
            entry.maxMillis = max(entry.maxMillis, millis)
            entry.lastMillis = millis
            entry.meanMillis = entry.totalMillis / Double(entry.calls)
            entries[name] = entry
        }
    }

    func snapshot() -> [FacadeTiming] { lock.withLock { Array(entries.values) } }
    func reset() { lock.withLock { entries = [:] } }
}

extension Workspace {
    /// Runs `body` and records how long it took under `name`, for `timings()`. The app wraps
    /// its facade calls in this at one place; the cache records its own folds and rebuilds
    /// (`cache.fold`, `cache.rebuild`).
    public nonisolated func timed<T: Sendable>(
        _ name: String, _ body: () async throws -> T
    ) async rethrows -> T {
        let clock = ContinuousClock()
        let start = clock.now
        defer { FacadeTimings.shared.record(name, clock.now - start) }
        return try await body()
    }

    /// The slowest calls recorded in this process, slowest single call first: a debug read.
    public nonisolated func timings(limit: Int = 20) -> [FacadeTiming] {
        Array(
            FacadeTimings.shared.snapshot()
                .sorted {
                    $0.maxMillis != $1.maxMillis ? $0.maxMillis > $1.maxMillis : $0.name < $1.name
                }
                .prefix(max(0, limit)))
    }

    /// Forgets every recorded timing.
    public nonisolated func resetTimings() { FacadeTimings.shared.reset() }
}
