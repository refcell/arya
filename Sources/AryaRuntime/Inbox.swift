import AryaAdapters
import AryaCore
import AryaLedger
import AryaMemory
import Foundation

// People reach a steward through its local inbox (decision 0038). A message comes from one of
// the charter's person bindings and says what the person wants: an answer, a correction, or to
// hand work over. Every message is recorded; a correction also becomes a memory note in the
// person's name; and when the charter takes messages from that person, the message starts a
// run. The steward answers through the same person binding, as an action whose output is the
// inbox entry (`BindingActionExecutor`), so `InboxBook` reads both directions as one thread.

/// What a person wants from a message.
public enum MessageIntent: String, Codable, Hashable, Sendable, CaseIterable {
    /// A question or request.
    case ask
    /// The steward got something wrong; the text says what is right. Kept as memory.
    case correct
    /// Work the person hands to the steward.
    case handoff
}

/// `inbox.message`: a person's message to a steward (actor: the person binding).
public struct InboxMessage: EventPayload {
    public static let type = EventType("inbox.message")
    /// The person binding id.
    public var from: String
    /// The binding's channel, for example `inbox` or an address its relay knows.
    public var channel: String
    /// The relay binding that carried it, for a person reached through `via`.
    public var via: String?
    public var intent: MessageIntent
    public var text: String
    /// The `memory.added` note a correction became.
    public var note: NoteID?

    /// Creates a payload.
    public init(
        from: String, channel: String, intent: MessageIntent, text: String, note: NoteID? = nil,
        via: String? = nil
    ) {
        self.via = via
        self.from = from
        self.channel = channel
        self.intent = intent
        self.text = text
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case from, channel, intent, text, note, via }
}

/// The inbox event types.
public enum InboxEventType {
    public static let message = InboxMessage.type.rawValue
}

/// Why the inbox refused a message.
public enum InboxError: Error, Equatable, Sendable {
    case unknownSteward(StewardID)
    /// The sender is not one of the steward's person bindings.
    case unknownSender(String)
    case emptyText
    /// The charter has no MCP binding with that id that lists the `receive` read tool.
    case unknownRelay(String)
}

/// What `Inbox.pull` did.
public struct RelayPull: Equatable, Sendable {
    public var receipts: [InboxReceipt]
    /// Messages skipped: unknown sender address, empty text, or unknown intent.
    public var skipped: Int
}

/// What posting a message did.
public struct InboxReceipt: Equatable, Sendable {
    /// The `inbox.message` event.
    public var message: EventID
    /// The note a correction became; nil when it repeats a live note or is not a correction.
    public var note: NoteID?
    /// True when the message started a run.
    public var triggered: Bool
}

/// The local inbox: records people's messages and turns them into runs and memory.
public struct Inbox: Sendable {
    private let engine: RunEngine
    private let scheduler: Scheduler

    /// Creates an inbox that starts message runs through `scheduler`.
    public init(engine: RunEngine, scheduler: Scheduler) {
        self.engine = engine
        self.scheduler = scheduler
    }

    /// Posts `text` from the person binding `sender` to `steward`.
    public func post(
        _ text: String, from sender: String, to steward: StewardID, intent: MessageIntent = .ask
    ) async throws -> InboxReceipt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InboxError.emptyText }
        let record = try await StewardLifecycle(sink: engine.sink).book().records[steward]
        guard let record else { throw InboxError.unknownSteward(steward) }
        let binding = record.charter.bindings.first { $0.kind == .person && $0.id == sender }
        guard let binding else { throw InboxError.unknownSender(sender) }

        let noteID: NoteID? = intent == .correct ? engine.ambient.newID(NoteID.self) : nil
        var note: MemoryNote?
        if let noteID, try await !Self.known(trimmed, steward: steward, engine.sink) {
            note = try MemoryNote(
                id: noteID, text: trimmed, tags: ["correction"],
                provenance: MemoryProvenance(author: MemoryAuthor(kind: .human, id: sender)))
        }
        let payload = InboxMessage(
            from: sender, channel: binding.channel ?? "inbox", intent: intent, text: trimmed,
            note: note?.id, via: binding.via)
        let message = try await engine.sink.append(
            RuntimeEventDraft(
                type: InboxEventType.message, steward: steward, actor: .person(sender),
                payload: try Payload.encode(payload)))
        if var note {
            note.provenance.event = message.id
            _ = try await engine.sink.append(
                RuntimeEventDraft(try .memoryAdded(note, steward: steward)))
        }
        let attachment: JSONValue = [
            "kind": "inbox", "message": .string(message.id.rawValue), "from": .string(sender),
            "intent": .string(intent.rawValue),
        ]
        let triggered = try await scheduler.deliver(
            Self.runText(trimmed, from: sender, intent: intent), from: sender, to: steward,
            attachments: [attachment])
        return InboxReceipt(message: message.id, note: note?.id, triggered: triggered)
    }

    /// The relay read tool that returns new messages (decision 0042).
    public static let receiveTool = "receive"

    /// Pulls new messages from `steward`'s relay binding `relay` (an MCP binding that its person
    /// bindings name in `via`): calls its `receive` tool, which returns
    /// `{messages: [{from, text, intent?}]}` with `from` a person's channel address, and posts
    /// each message from the person binding with that relay and channel. Messages from unknown
    /// addresses, with empty text, or with an unknown intent are skipped and counted; the relay
    /// is responsible for not returning a message twice.
    public func pull(
        _ relay: String, steward: StewardID,
        connect: @Sendable (CharterBinding) async throws -> any ToolUpstream
    ) async throws -> RelayPull {
        let record = try await StewardLifecycle(sink: engine.sink).book().records[steward]
        guard let record else { throw InboxError.unknownSteward(steward) }
        guard let binding = record.charter.binding(relay), binding.kind == .mcp,
            binding.read.contains(Self.receiveTool)
        else { throw InboxError.unknownRelay(relay) }
        let people = record.charter.bindings.filter { $0.kind == .person && $0.via == relay }
        let upstream = try await connect(binding)
        let result: JSONValue
        do {
            result = try await upstream.call(Self.receiveTool, arguments: [:])
            await upstream.close()
        } catch {
            await upstream.close()
            throw error
        }
        var pull = RelayPull(receipts: [], skipped: 0)
        let messages = (result["structuredContent"] ?? result)["messages"]?.arrayValue ?? []
        for message in messages {
            let intent = message["intent"].map { $0.stringValue.flatMap(MessageIntent.init) }
            guard let from = message["from"]?.stringValue, let text = message["text"]?.stringValue,
                let person = people.first(where: { $0.channel == from }),
                let intent = intent ?? .ask
            else {
                pull.skipped += 1
                continue
            }
            do {
                pull.receipts.append(
                    try await post(text, from: person.id, to: steward, intent: intent))
            } catch InboxError.emptyText {
                pull.skipped += 1
            }
        }
        return pull
    }

    /// The run input for a message: who sent it and what they want, then the text.
    static func runText(_ text: String, from sender: String, intent: MessageIntent) -> String {
        switch intent {
        case .ask: "\(sender) asks: \(text)"
        case .correct: "\(sender) corrects you (kept in memory): \(text)"
        case .handoff: "\(sender) hands this to you: \(text)"
        }
    }

    private static func known(_ text: String, steward: StewardID, _ sink: any EventSink)
        async throws -> Bool
    {
        let memory = try MemoryView(try await sink.events(from: 1)).memory
        return memory.liveNotes(steward: steward).contains { $0.note.text == text }
    }
}

/// One entry of a steward's inbox thread.
public struct InboxEntry: Equatable, Sendable {
    public enum Direction: String, Equatable, Sendable { case inbound, outbound }

    public var seq: Int
    public var at: Timestamp
    public var direction: Direction
    /// The person binding: the sender of an inbound message, the recipient of an outbound one.
    public var person: String
    public var channel: String
    /// Inbound only.
    public var intent: MessageIntent?
    /// The message text; for outbound entries, `params.text`, `params.body`, or
    /// `params.message`, when present.
    public var text: String?
    /// The run that sent an outbound entry.
    public var run: RunID?
    /// The outbound action's kind, for example `reply`.
    public var action: String?
}

/// Each steward's inbox thread, oldest first: people's messages and the steward's deliveries
/// through person bindings.
public struct InboxBook: Sendable {
    public private(set) var threads: [StewardID: [InboxEntry]] = [:]

    /// Folds `events` in order.
    public init(_ events: [RuntimeEvent]) throws {
        for event in events {
            guard let steward = event.draft.steward else { continue }
            if event.type == InboxEventType.message {
                let message = try Payload.decode(InboxMessage.self, event.draft.payload)
                threads[steward, default: []].append(
                    InboxEntry(
                        seq: event.seq, at: event.at, direction: .inbound, person: message.from,
                        channel: message.channel, intent: message.intent, text: message.text))
            } else if event.type == ActionEventType.executed,
                let output = event.draft.payload["output"],
                let person = output["inbox"]?.stringValue
            {
                let params = output["params"]
                let text = ["text", "body", "message"].lazy.compactMap { params?[$0]?.stringValue }
                    .first
                threads[steward, default: []].append(
                    InboxEntry(
                        seq: event.seq, at: event.at, direction: .outbound, person: person,
                        channel: output["channel"]?.stringValue ?? "inbox", text: text,
                        run: event.draft.run, action: event.draft.payload["action"]?.stringValue))
            }
        }
    }
}
