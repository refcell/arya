import Foundation

/// One person's conversation with a steward, read from the ledger: their `inbox.message`
/// events (inbound) and the steward's deliveries to them, the `action.executed` events whose
/// output names their binding as `inbox`, and the periodic reports sent to them (`report.sent`)
/// (outbound). Hand-offs are also tasks, with the status
/// of the run whose input attaches the message (`run.started` input attachment `message`).
struct PeopleThread: Hashable, Sendable {
    struct Entry: Hashable, Sendable, Identifiable {
        /// The event id.
        var id: String
        var seq: Int
        var at: Date
        var inbound: Bool
        /// `ask`, `correct`, or `handoff`, for inbound messages.
        var intent: String?
        var text: String
        /// The run that sent an outbound entry.
        var run: String?
        /// The outbound action's kind, for example `reply`.
        var action: String?
    }

    /// Where a handed-off task stands, from its run.
    enum Status: String, Hashable, Sendable {
        /// No run took it yet (the steward takes no live messages from this person).
        case queued
        case running
        /// Its run waits on an approval.
        case waiting
        case done
        case failed

        var label: String {
            switch self {
            case .queued: "queued"
            case .running: "running"
            case .waiting: "needs approval"
            case .done: "done"
            case .failed: "failed"
            }
        }
    }

    struct Task: Hashable, Sendable, Identifiable {
        /// The hand-off message's event id.
        var id: String
        var at: Date
        var text: String
        var run: String?
        var status: Status
    }

    /// A run answering this person that is still going: what the steward is doing right now.
    struct Working: Hashable, Sendable {
        var run: String
        var since: Date
        /// The adapter's latest status or tool call, for example "calling inbox.search".
        var doing: String
        /// Steps the run has recorded so far.
        var steps: Int
    }

    var person: String
    /// The newest active run started by this person's message, nil when none is.
    var working: Working?
    /// Oldest first.
    var entries: [Entry]
    /// Newest first.
    var tasks: [Task]

    /// `conversation`, when the facade's read has loaded, supplies the messages and replies;
    /// reports, hand-off tasks, and the working line always come from `events`.
    init(
        events: [FeatureEvent], steward: String, person: String,
        conversation: [FeatureConversationEntry]? = nil
    ) {
        self.person = person
        var entries: [Entry] = []
        var handoffs: [Entry] = []
        // Message event id → run that took it; run → its last state.
        var runFor: [String: String] = [:]
        var ended: [String: Bool] = [:]
        var pending: [String: Set<String>] = [:]
        // Runs started by this person's messages, oldest first, and what each is doing.
        var theirs: [(run: String, at: Date)] = []
        var doing: [String: String] = [:]
        var steps: [String: Int] = [:]
        // Actions addressed to this person (binding is their id), by run and action id.
        var addressed: [String: FeatureJSON] = [:]
        for event in events where event.steward == steward {
            switch event.type {
            case "inbox.message" where event.payload["from"]?.string == person:
                let entry = Entry(
                    id: event.id, seq: event.seq, at: event.at, inbound: true,
                    intent: event.payload["intent"]?.string,
                    text: event.payload["text"]?.string ?? "")
                entries.append(entry)
                if entry.intent == "handoff" { handoffs.append(entry) }
            case "action.proposed":
                if let run = event.run, let action = event.payload["action"],
                    action["binding"]?.string == person, let id = action["id"]?.string
                {
                    addressed["\(run)/\(id)"] = action
                }
            case "action.executed":
                // The proposed action says who it was for (dry runs and relays record no inbox
                // entry); an older executor's output may name the inbox instead.
                let id = event.payload["action"]?.string ?? ""
                let proposed = event.run.flatMap { addressed["\($0)/\(id)"] }
                let output = event.payload["output"]
                guard proposed != nil || output?["inbox"]?.string == person else { continue }
                let params = proposed?["params"] ?? output?["params"]
                let text = ["text", "body", "message"].lazy.compactMap { params?[$0]?.string }
                    .first
                entries.append(
                    Entry(
                        id: event.id, seq: event.seq, at: event.at, inbound: false, intent: nil,
                        text: text ?? "",
                        run: event.run, action: proposed?["kind"]?.string ?? id))
            case "report.sent":
                let to = event.payload["to"]?.array?.compactMap { $0["person"]?.string } ?? []
                guard to.contains(person) else { continue }
                entries.append(
                    Entry(
                        id: event.id, seq: event.seq, at: event.at, inbound: false, intent: nil,
                        text: event.payload["text"]?.string ?? "", run: nil, action: "report"))
            case "run.started":
                guard let run = event.run else { continue }
                for attachment in event.payload["input"]?["attachments"]?.array ?? [] {
                    if let message = attachment["message"]?.string { runFor[message] = run }
                    if attachment["from"]?.string == person { theirs.append((run, event.at)) }
                }
            case "run.adapter.event":
                guard let run = event.run,
                    let inner = event.payload["message"]?["params"]?["event"]
                else { continue }
                steps[run, default: 0] += 1
                switch inner["kind"]?.string {
                case "status": doing[run] = inner["detail"]?.string ?? doing[run]
                case "tool_call": doing[run] = inner["tool"]?.string.map { "calling \($0)" }
                case "thinking": doing[run] = "thinking"
                default: break
                }
            case "run.finished": if let run = event.run { ended[run] = true }
            case "run.failed": if let run = event.run { ended[run] = false }
            case "approval.requested":
                if let run = event.run, let id = event.payload["approval"]?.string {
                    pending[run, default: []].insert(id)
                }
            case "approval.granted", "approval.denied", "approval.expired":
                if let run = event.run, let id = event.payload["approval"]?.string {
                    pending[run]?.remove(id)
                }
            default: continue
            }
        }
        if let conversation {
            // Kind and event id come from the ledger event at that seq.
            let bySeq = Dictionary(
                events.map { ($0.seq, $0) }, uniquingKeysWith: { first, _ in first })
            let actions = Dictionary(
                entries.filter { !$0.inbound }.map { ($0.seq, $0.action) },
                uniquingKeysWith: { first, _ in first })
            entries =
                (conversation.map { item in
                    Entry(
                        id: bySeq[item.seq]?.id ?? "seq-\(item.seq)", seq: item.seq,
                        at: bySeq[item.seq]?.at ?? .distantPast, inbound: item.inbound,
                        intent: item.intent, text: item.text ?? "", run: item.run,
                        action: item.inbound ? nil : (actions[item.seq] ?? "reply"))
                } + entries.filter { $0.action == "report" }).sorted { $0.seq < $1.seq }
        }
        self.entries = entries
        working = theirs.last { ended[$0.run] == nil && (pending[$0.run]?.isEmpty ?? true) }
            .map {
                Working(
                    run: $0.run, since: $0.at, doing: doing[$0.run] ?? "starting",
                    steps: steps[$0.run] ?? 0)
            }
        tasks = handoffs.reversed().map { message in
            let run = runFor[message.id]
            let status: Status =
                switch run.map({ (ended[$0], pending[$0]?.isEmpty ?? true) }) {
                case nil: .queued
                case (false?, _)?: .failed
                // A run may finish with its action still held for a person.
                case (_, false)?: .waiting
                case (true?, true)?: .done
                case (nil, true)?: .running
                }
            return Task(
                id: message.id, at: message.at, text: message.text, run: run, status: status)
        }
    }

    /// Handed-off tasks still open (queued, running, or waiting).
    var open: Int { tasks.filter { [.queued, .running, .waiting].contains($0.status) }.count }
}
