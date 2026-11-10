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
    /// The people a relay connection carries messages for, by name, with the steward when more
    /// than one uses it: "Sam, Priya (Support inbox triage)". Nil when it relays for no one.
    static func carries(
        _ catalog: ConnectionsCatalog, entry: ConnectionsCatalog.Entry, events: [FeatureEvent]
    ) -> String? {
        guard let bySteward = catalog.relays[entry.id], !bySteward.isEmpty else { return nil }
        let names = StewardNames.build(events: events)
        return bySteward.keys.sorted().map { steward in
            let directory = PeopleDirectory(events: events, steward: steward)
            let people = bySteward[steward, default: []].map { id in
                directory.people.first { $0.id == id }?.name ?? PeopleDirectory.displayName(id)
            }
            return people.joined(separator: ", ") + " (\(names[steward] ?? steward))"
        }.joined(separator: "; ")
    }

    /// The newest messages a relay carried in (`inbox.message` with `via`), newest first.
    static func relayed(_ connection: String, events: [FeatureEvent], limit: Int = 3)
        -> [FeatureEvent]
    {
        Array(
            events.filter {
                $0.type == "inbox.message" && $0.payload["via"]?.string == connection
            }.suffix(limit).reversed())
    }

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

    /// What the ledger says when nobody tested it this session (a test is a session diagnostic,
    /// never recorded): "working · last call 2h ago" or "last call failed 2h ago"; nil without
    /// a settled call.
    static func evidence(_ call: ConnectionActivity.Call?, now: Date) -> String? {
        guard let call else { return nil }
        let when = FeatureTime.phrase(call.at, now: now)
        return call.kind == .failed ? "last call failed \(when)" : "working · last call \(when)"
    }

    /// "secret stored"; a local server (no network) needs none; else "no secret".
    static func secret(stored: Bool, network: Bool) -> String {
        stored ? "secret stored" : network ? "no secret" : "no secret needed"
    }

    /// The last test in one line, or that it has not run.
    static func lastTest(_ test: ConnectionTest?) -> String {
        guard let test else { return "Not tested yet" }
        guard test.ok else { return "Failed · " + (test.problem ?? "no answer") }
        return ConnectionTestText.line(test)
    }
}
