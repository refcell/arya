import AryaCore
import AryaLedger
import AryaMemory

// What a steward knows about the people and systems around it (decision 0047), projected from
// its charter and the ledger: the people it can reach (person bindings) or has heard from
// (inbox messages, approval decisions, memory authors), the connections it reads and acts
// through (MCP bindings) with how much it used them, and the live memory notes about each.
// A note is about a person when it names their binding id or channel address, or a person
// wrote it.

/// A person a steward knows.
public struct ContextPerson: Sendable, Hashable {
    /// The person binding id, or the actor id of someone met only in the ledger.
    public var id: String
    /// How the steward reaches them; nil when they are not a binding.
    public var channel: String?
    /// The relay binding for email or chat (decision 0042).
    public var via: String?
    /// True when the charter names them as a person binding.
    public var bound: Bool
    public var messages: Int
    public var corrections: Int
    /// Approvals they decided.
    public var decisions: Int
    public var lastSeen: Timestamp?
    /// Live notes about or by them, oldest first.
    public var notes: [NoteID]
}

/// A system a steward is connected to.
public struct ContextConnection: Sendable, Hashable {
    public var id: String
    public var read: [String]
    public var actions: [String]
    public var network: Bool
    public var toolCalls: Int
    public var actionsExecuted: Int
    public var actionsFailed: Int
    /// Actions only drafted through it (dry runs): nothing was sent.
    public var actionsDrafted: Int = 0
    public var lastUsed: Timestamp?
    /// Live notes that name it, oldest first.
    public var notes: [NoteID]
}

/// The people and connections of one steward.
public struct StewardContext: Sendable, Hashable {
    public var steward: StewardID
    public var people: [ContextPerson]
    public var connections: [ContextConnection]

    /// Projects the context of `steward` from `events`; nil when it does not exist.
    public init?(_ events: [RuntimeEvent], steward: StewardID) throws {
        guard let charter = try StewardBook(events).records[steward]?.charter else { return nil }
        self.steward = steward
        let notes = try MemoryView(events).memory.liveNotes(steward: steward).map(\.note)
        var people: [String: ContextPerson] = [:]
        var order: [String] = []
        func person(_ id: String) -> ContextPerson {
            people[id]
                ?? ContextPerson(
                    id: id, channel: nil, via: nil, bound: false, messages: 0, corrections: 0,
                    decisions: 0, lastSeen: nil, notes: [])
        }
        func touch(_ id: String, at: Timestamp, _ change: (inout ContextPerson) -> Void) {
            if people[id] == nil { order.append(id) }
            var entry = person(id)
            change(&entry)
            entry.lastSeen = max(entry.lastSeen ?? at, at)
            people[id] = entry
        }
        for binding in charter.bindings where binding.kind == .person {
            order.append(binding.id)
            var entry = person(binding.id)
            entry.channel = binding.channel
            entry.via = binding.via
            entry.bound = true
            people[binding.id] = entry
        }
        var connections = Dictionary(
            uniqueKeysWithValues: charter.bindings.filter { $0.kind == .mcp }.map {
                (
                    $0.id,
                    ContextConnection(
                        id: $0.id, read: $0.read, actions: $0.actions, network: $0.network,
                        toolCalls: 0, actionsExecuted: 0, actionsFailed: 0, lastUsed: nil,
                        notes: [])
                )
            })
        let actionBindings = Self.actionBindings(events, steward: steward)
        for event in events where event.draft.steward == steward {
            let actor = event.draft.actor
            switch event.type {
            case InboxEventType.message:
                let message = try Payload.decode(InboxMessage.self, event.draft.payload)
                touch(message.from, at: event.at) {
                    $0.messages += 1
                    if message.intent == .correct { $0.corrections += 1 }
                }
            case "approval.granted", "approval.denied":
                if actor.kind == "human" { touch(actor.id, at: event.at) { $0.decisions += 1 } }
            case EventType.runToolCall.rawValue:
                if let id = event.draft.payload["binding"]?.stringValue, connections[id] != nil {
                    connections[id]?.toolCalls += 1
                    connections[id]?.lastUsed = event.at
                }
            case ActionEventType.executed, ActionEventType.failed:
                let key =
                    "\(event.draft.run?.rawValue ?? ""):"
                    + (event.draft.payload["action"]?.stringValue ?? "")
                if let id = actionBindings[key], connections[id] != nil {
                    if event.type == ActionEventType.executed,
                        event.draft.payload["dryRun"] == true
                    {
                        connections[id]?.actionsDrafted += 1
                    } else if event.type == ActionEventType.executed {
                        connections[id]?.actionsExecuted += 1
                    } else {
                        connections[id]?.actionsFailed += 1
                    }
                    connections[id]?.lastUsed = event.at
                }
            default: break
            }
        }
        for note in notes {
            let text = note.text.lowercased()
            let author = note.provenance.author
            for id in order {
                let entry = person(id)
                let named = [entry.id, entry.channel].compactMap { $0?.lowercased() }
                    .contains { !$0.isEmpty && text.contains($0) }
                if named || (author.kind == .human && author.id == id) {
                    people[id]?.notes.append(note.id)
                }
            }
            for id in connections.keys where text.contains(id.lowercased()) {
                connections[id]?.notes.append(note.id)
            }
        }
        self.people = order.compactMap { people[$0] }
        self.connections = charter.bindings.compactMap { connections[$0.id] }
    }

    /// `<run>:<action id>` to the binding of each proposed action.
    private static func actionBindings(_ events: [RuntimeEvent], steward: StewardID)
        -> [String: String]
    {
        var out: [String: String] = [:]
        for event in events
        where event.draft.steward == steward && event.type == ActionEventType.proposed {
            guard let id = event.draft.payload["action"]?["id"]?.stringValue,
                let binding = event.draft.payload["action"]?["binding"]?.stringValue
            else { continue }
            out["\(event.draft.run?.rawValue ?? ""):\(id)"] = binding
        }
        return out
    }
}

/// Live memory notes of a steward, from runtime events.
public enum MemoryNotes {
    /// The steward's live notes, oldest first.
    public static func live(_ events: [RuntimeEvent], steward: StewardID) throws -> [MemoryNote] {
        try MemoryView(events).memory.liveNotes(steward: steward).map(\.note)
    }
}
