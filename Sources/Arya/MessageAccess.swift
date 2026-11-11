import AryaCore
import AryaRuntime
import Foundation

// Message intents honor grants (M3.6 #13): once a home has grants, a person correcting a
// steward needs `use` on it, one of its connections, or one of their tools. Asking only needs
// the person bound to the steward (`message` checks that), as the binding is what lets them
// see its work. A hand-off is let in:
// the run it starts is gated where the work happens, each action needing the person's `use`
// grant (runtime), so a hand-off from someone without one ends as a recorded refused action.
// The owner is never limited. A refusal is recorded as `access.refused`, like the runtime's
// use and approve refusals, so Settings ▸ Access lists it.

extension Workspace {
    /// Throws, after recording `access.refused`, when `person` may not send `intent` to
    /// `steward`.
    func requireMessageAccess(_ person: String, steward: StewardID, intent: MessageIntent)
        async throws
    {
        guard !Access.isOwner(person), intent == .correct else { return }
        let book = try await sink.book(AccessBook.self)
        guard book.enforced else { return }
        let who = Access.person(person)
        // The steward, its connections, and their tools: a grant on any of them is a grant to
        // work with this steward.
        var resources = ["steward:\(steward.rawValue)"]
        for binding in try await existing(steward.rawValue).charter.bindings
        where binding.kind == .mcp {
            resources.append("connection:\(binding.id)")
            resources += binding.actions.map { "tool:\(binding.id).\($0)" }
        }
        let levels: [AccessLevel] = [.use]
        let grants = book.inForce
        if levels.contains(where: { grants.grant($0, person: who, on: resources) != nil }) {
            return
        }
        let need = AccessLevel.use
        let holders = levels.flatMap { grants.holders($0, on: resources) }
        let only =
            holders.isEmpty
            ? "nobody holds one" : "only \(Array(Set(holders)).sorted().joined(separator: ", "))"
        let reason =
            "\(who) has no \(need.rawValue) grant to \(intent.rawValue) \(steward.rawValue) or "
            + "its tools; "
            + "\(only)"
        _ = try await sink.append(
            RuntimeEventDraft(
                type: AccessEventType.refused, steward: steward, run: nil,
                actor: .person(person),
                payload: try CanonicalJSON.decode(
                    JSONValue.self,
                    from: try CanonicalJSON.encode(
                        AccessRefused(
                            person: who, level: need, action: "message.\(intent.rawValue)",
                            resources: resources, reason: reason)))))
        throw WorkspaceError.rejected(reason)
    }
}
