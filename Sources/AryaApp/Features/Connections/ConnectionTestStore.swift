import Arya
import Foundation

/// Connection test results shared by the Connections page and the inspector: the last result
/// per connection id, and which tests are running. Held by the app model for the session; a
/// test is a diagnostic, never recorded.
@MainActor
final class ConnectionTestStore: ObservableObject {
    @Published var results: [String: ConnectionTest] = [:]
    @Published private(set) var testing: Set<String> = []

    /// Runs `probe` for `entry` with `secret` and keeps its result; an error becomes a failed
    /// result in words.
    func run(
        _ entry: ConnectionsCatalog.Entry, secret: String?,
        probe:
            @escaping @Sendable (ConnectionsCatalog.Entry, String?) async throws
            -> ConnectionTest
    ) {
        guard !testing.contains(entry.id) else { return }
        testing.insert(entry.id)
        Task {
            do {
                results[entry.id] = try await probe(entry, secret)
            } catch {
                results[entry.id] = ConnectionTest(
                    ok: false, problem: ConnectionsFailure(error).text)
            }
            testing.remove(entry.id)
        }
    }
}

/// Connection text, kept apart from layout so it can be tested.
enum ConnectionsText {
    /// "reads: search, get · does: label (low), reply (medium)".
    static func capabilities(_ entry: ConnectionsCatalog.Entry) -> String {
        var parts: [String] = []
        if !entry.read.isEmpty { parts.append("reads: " + entry.read.joined(separator: ", ")) }
        if !entry.actions.isEmpty {
            parts.append(
                "does: " + entry.actions.map { "\($0.kind) (\($0.risk))" }.joined(separator: ", "))
        }
        return parts.isEmpty ? "reads and does nothing yet" : parts.joined(separator: " · ")
    }

    /// The last test in one line, or that it has not run.
    static func lastTest(_ test: ConnectionTest?) -> String {
        guard let test else { return "Not tested yet" }
        guard test.ok else { return "Failed · " + (test.problem ?? "no answer") }
        return ConnectionTestText.line(test)
    }
}
