import AryaCore
import AryaLedger

// The approval queue (ARCHITECTURE.md "Runs", step 4). An `ask` action or a `host/ask` question
// becomes `approval.requested`; a person grants or denies it, or it expires. The queue's state
// is a projection of those events, so pending approvals survive restarts unchanged.

/// Ledger event types the approval queue writes.
public enum ApprovalEventType {
    /// An action or question is waiting for a person.
    public static let requested = EventType.approvalRequested.rawValue
    /// A person granted (or answered) it.
    public static let granted = EventType.approvalGranted.rawValue
    /// A person denied it.
    public static let denied = EventType.approvalDenied.rawValue
    /// Nobody decided before it expired.
    public static let expired = EventType.approvalExpired.rawValue
}

extension ProposedAction {
    /// The policy view of this action.
    public var policyAction: PolicyAction { policyAction(routines: [:]) }

    /// The policy view of this action, with live routine versions by name for `routine`.
    public func policyAction(routines: [String: String]) -> PolicyAction {
        let name = kind == ActionPolicy.routineKind ? params?["name"]?.stringValue : nil
        return PolicyAction(
            kind: kind, binding: binding, routineName: name,
            routineVersion: name.flatMap { routines[$0] })
    }
}

/// What a person is asked to decide.
public enum ApprovalSubject: Sendable, Hashable, Codable {
    /// A proposed action held by policy.
    case action(ProposedAction)
    /// A question from a run (`host/ask`).
    case question(String)

    enum CodingKeys: String, CodingKey { case action, question }

    // Coded as `{"action":{…}}` or `{"question":"…"}` (only the book cache stores it).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let action = try container.decodeIfPresent(ProposedAction.self, forKey: .action) {
            self = .action(action)
        } else {
            self = .question(try container.decode(String.self, forKey: .question))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .action(let action): try container.encode(action, forKey: .action)
        case .question(let question): try container.encode(question, forKey: .question)
        }
    }
}

/// Where an approval is.
public enum ApprovalStatus: String, Sendable, Hashable, Codable {
    /// Waiting for a person.
    case pending
    /// Granted, or answered for a question.
    case granted
    /// Denied.
    case denied
    /// Expired undecided.
    case expired
}

/// One approval as projected from the ledger.
public struct ApprovalRecord: Sendable, Hashable, Codable {
    enum CodingKeys: String, CodingKey {
        case id, steward, run, subject, to, requestedAt, expiresAt, status, decidedBy, note, seq
    }

    /// Approval id.
    public var id: ApprovalID
    /// Steward that asked.
    public var steward: StewardID
    /// Run that asked.
    public var run: RunID
    /// What is being decided.
    public var subject: ApprovalSubject
    /// Who should decide: `local` or a contact id.
    public var to: String
    /// When it was requested.
    public var requestedAt: Timestamp
    /// When it expires undecided, if ever.
    public var expiresAt: Timestamp?
    /// Status.
    public var status: ApprovalStatus
    /// The deciding person, once granted or denied.
    public var decidedBy: RuntimeActor?
    /// The note or answer given with the decision.
    public var note: String?
    /// Ledger `seq` of the request, which orders the queue.
    public var seq: Int
}

/// Why an approval operation was refused.
public enum ApprovalError: Error, Equatable, Sendable {
    /// No approval has this id.
    case notFound(ApprovalID)
    /// The approval was already decided or expired.
    case alreadyDecided(ApprovalID, ApprovalStatus)
}

/// Folds approval events into records.
public struct ApprovalBook: RuntimeBook {
    /// Records by id.
    public private(set) var records: [ApprovalID: ApprovalRecord] = [:]

    public static let cacheName = "runtime.approvals.v1"

    enum CodingKeys: String, CodingKey { case records }

    /// An empty book.
    public init() {}

    /// Builds a book from events in ledger order.
    public init(_ events: [RuntimeEvent]) throws {
        for event in events { try apply(event) }
    }

    /// Pending approvals, oldest first.
    public var pending: [ApprovalRecord] { all.filter { $0.status == .pending } }

    /// Every approval, oldest first.
    public var all: [ApprovalRecord] { records.values.sorted { $0.seq < $1.seq } }

    /// Applies one event; events of other types are ignored.
    public mutating func apply(_ event: RuntimeEvent) throws {
        switch event.type {
        case ApprovalEventType.requested:
            try applyRequest(event)
        case ApprovalEventType.granted:
            try applyDecision(event, .granted)
        case ApprovalEventType.denied:
            try applyDecision(event, .denied)
        case ApprovalEventType.expired:
            try applyDecision(event, .expired)
        default:
            return
        }
    }

    private mutating func applyRequest(_ event: RuntimeEvent) throws {
        let body = try Payload.decode(ApprovalRequested.self, event.payload)
        guard let steward = event.draft.steward, let run = event.draft.run else { return }
        let subject: ApprovalSubject =
            if let action = body.action { .action(action) } else { .question(body.question ?? "") }
        records[body.approval] = ApprovalRecord(
            id: body.approval, steward: steward, run: run, subject: subject, to: body.to,
            requestedAt: event.at, expiresAt: body.expiresAt, status: .pending, decidedBy: nil,
            note: nil, seq: event.seq)
    }

    private mutating func applyDecision(_ event: RuntimeEvent, _ status: ApprovalStatus) throws {
        let body = try Payload.decode(ApprovalGranted.self, event.payload)
        guard var record = records[body.approval], record.status == .pending else { return }
        record.status = status
        record.note = body.note
        record.decidedBy = status == .expired ? nil : event.draft.actor
        records[body.approval] = record
    }
}

/// Requests, decides, and expires approvals by appending events to a sink.
public struct ApprovalQueue: Sendable {
    private let sink: any EventSink
    private let ambient: Ambient

    /// Creates a queue over a sink.
    public init(sink: any EventSink, ambient: Ambient) {
        self.sink = sink
        self.ambient = ambient
    }

    /// The current book.
    public func book() async throws -> ApprovalBook {
        try await sink.book(ApprovalBook.self)
    }

    /// Records `approval.requested` and returns the new pending record.
    @discardableResult
    public func request(
        _ subject: ApprovalSubject, steward: StewardID, run: RunID, to: String = "local",
        expiresAt: Timestamp? = nil
    ) async throws -> ApprovalRecord {
        let id = ambient.newID(ApprovalID.self)
        let payload: ApprovalRequested =
            switch subject {
            case .action(let action):
                ApprovalRequested(approval: id, action: action, to: to, expiresAt: expiresAt)
            case .question(let text):
                ApprovalRequested(approval: id, question: text, to: to, expiresAt: expiresAt)
            }
        let event = try await sink.append(
            RuntimeEventDraft(
                type: ApprovalEventType.requested, steward: steward, run: run,
                actor: .steward(steward), payload: try Payload.encode(payload)))
        var book = ApprovalBook()
        try book.apply(event)
        guard let record = book.records[id] else { throw ApprovalError.notFound(id) }
        return record
    }

    /// Grants a pending approval on behalf of `person`.
    @discardableResult
    public func grant(_ id: ApprovalID, by person: RuntimeActor, note: String? = nil)
        async throws -> ApprovalRecord
    {
        try await decide(id, type: ApprovalEventType.granted, actor: person, note: note)
    }

    /// Denies a pending approval on behalf of `person`.
    @discardableResult
    public func deny(_ id: ApprovalID, by person: RuntimeActor, note: String? = nil)
        async throws -> ApprovalRecord
    {
        try await decide(id, type: ApprovalEventType.denied, actor: person, note: note)
    }

    /// Expires every pending approval whose `expiresAt` is at or before `now`, oldest first.
    @discardableResult
    public func expireDue(now: Timestamp) async throws -> [ApprovalRecord] {
        var expired: [ApprovalRecord] = []
        for record in try await book().pending {
            guard let deadline = record.expiresAt, deadline <= now else { continue }
            expired.append(
                try await decide(record.id, type: ApprovalEventType.expired, actor: .system))
        }
        return expired
    }

    private func decide(
        _ id: ApprovalID, type: String, actor: RuntimeActor, note: String? = nil
    ) async throws -> ApprovalRecord {
        guard let record = try await book().records[id] else { throw ApprovalError.notFound(id) }
        guard record.status == .pending else {
            throw ApprovalError.alreadyDecided(id, record.status)
        }
        _ = try await sink.append(
            RuntimeEventDraft(
                type: type, steward: record.steward, run: record.run, actor: actor,
                payload: try Payload.encode(ApprovalGranted(approval: id, note: note))))
        // A concurrent decision by another process may have landed first; the book keeps the
        // first decision, so report what the ledger now says.
        return try ApprovalBook(try await sink.events(from: record.seq)).records[id] ?? record
    }
}
