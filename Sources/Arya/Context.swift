import AryaCore
import AryaRuntime
import Foundation

/// What a steward knows about the people and systems around it (decision 0047).
public struct ContextSummary: Sendable, Hashable, Codable {
    public struct Person: Sendable, Hashable, Codable {
        public var id: String
        public var channel: String?
        /// The relay binding (email, chat) that reaches them.
        public var via: String?
        /// True when the charter names them; false for someone met only in the ledger.
        public var bound: Bool
        public var messages: Int
        public var corrections: Int
        /// Approvals they decided.
        public var decisions: Int
        public var lastSeen: Date?
        /// Texts of live memory notes about or by them, oldest first.
        public var notes: [String]
    }

    public struct Connection: Sendable, Hashable, Codable {
        public var id: String
        public var read: [String]
        public var actions: [String]
        public var network: Bool
        public var toolCalls: Int
        public var actionsExecuted: Int
        public var actionsFailed: Int
        public var lastUsed: Date?
        /// Texts of live memory notes that name it, oldest first.
        public var notes: [String]
    }

    public var steward: String
    public var people: [Person]
    public var connections: [Connection]
}

extension Workspace {
    /// The people a steward knows (person bindings and anyone who messaged it or decided its
    /// approvals) and the connections it uses (MCP bindings with use counts), each with the
    /// live memory notes about it.
    public func context(steward: String) async throws -> ContextSummary {
        let id = try await existing(steward).id
        let events = try facadeState().runtime
        guard let context = try StewardContext(events, steward: id) else {
            throw WorkspaceError.notFound(steward)
        }
        let texts = Dictionary(
            try MemoryNotes.live(events, steward: id).map { ($0.id, $0.text) },
            uniquingKeysWith: { first, _ in first })
        return ContextSummary(
            steward: id.rawValue,
            people: context.people.map {
                ContextSummary.Person(
                    id: $0.id, channel: $0.channel, via: $0.via, bound: $0.bound,
                    messages: $0.messages, corrections: $0.corrections, decisions: $0.decisions,
                    lastSeen: $0.lastSeen?.date, notes: $0.notes.compactMap { texts[$0] })
            },
            connections: context.connections.map {
                ContextSummary.Connection(
                    id: $0.id, read: $0.read, actions: $0.actions, network: $0.network,
                    toolCalls: $0.toolCalls, actionsExecuted: $0.actionsExecuted,
                    actionsFailed: $0.actionsFailed, lastUsed: $0.lastUsed?.date,
                    notes: $0.notes.compactMap { texts[$0] })
            })
    }
}
