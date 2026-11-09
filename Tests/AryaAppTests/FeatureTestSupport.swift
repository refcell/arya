import Foundation

/// A fixed reference time for feature tests.
enum FeatureTestClock {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
}

struct FeatureTimeout: Error {}

/// Polls `condition` on the main actor until it holds, failing after about two seconds.
@MainActor
func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw FeatureTimeout()
}
