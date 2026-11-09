import AryaCore

// Steward lifecycle (ARCHITECTURE.md "The ledger", `steward.*`). A steward is created from a
// validated charter at version 1; each charter update bumps the version by one; it can be
// paused, resumed, and retired. Readiness (`steward.ready`) is recorded by the eval lane and
// only read here. All state is a projection of these events.

/// Ledger event types for the steward lifecycle.
public enum StewardEventType {
    /// A steward was created with its first charter.
    public static let created = "steward.created"
    /// The live charter changed.
    public static let charterUpdated = "steward.charter.updated"
    /// A person marked the steward ready for live triggers.
    public static let ready = "steward.ready"
    /// The steward takes no triggers until resumed.
    public static let paused = "steward.paused"
    /// A paused steward takes triggers again.
    public static let resumed = "steward.resumed"
    /// The steward is gone for good.
    public static let retired = "steward.retired"
}

/// Lifecycle status of a steward.
public enum StewardStatus: String, Sendable, Hashable, Codable {
    /// Takes triggers (live ones only once ready).
    case active
    /// Takes no triggers.
    case paused
    /// Gone for good.
    case retired
}

/// One steward as projected from the ledger.
public struct StewardRecord: Sendable, Hashable {
    /// Steward id.
    public var id: StewardID
    /// The live charter.
    public var charter: Charter
    /// Live charter version, from 1.
    public var version: Int
    /// Lifecycle status.
    public var status: StewardStatus
    /// True once a person marked it ready.
    public var ready: Bool
    /// When it was created.
    public var createdAt: Timestamp

    /// True when the steward may take live (scheduled or message) triggers.
    public var takesLiveTriggers: Bool { status == .active && ready }
}

/// Why a lifecycle operation was refused.
public enum StewardError: Error, Equatable, Sendable {
    /// No steward has this id.
    case notFound(StewardID)
    /// A steward with this id already exists.
    case alreadyExists(StewardID)
    /// The charter breaks validation rules.
    case invalidCharter([CharterIssue])
    /// An update named a different steward id than the steward it targets.
    case idMismatch(expected: StewardID, got: StewardID)
    /// The steward is not in a status that allows the operation.
    case wrongStatus(StewardID, StewardStatus)
}

struct CharterPayload: Codable, Hashable {
    var charter: Charter
    var version: Int
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case charter, version, reason
    }
}

struct ReasonPayload: Codable, Hashable {
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case reason
    }
}

/// Folds steward events into records.
public struct StewardBook: Sendable {
    /// Records by id.
    public private(set) var records: [StewardID: StewardRecord] = [:]

    /// An empty book.
    public init() {}

    /// Builds a book from events in ledger order.
    public init(_ events: [RuntimeEvent]) throws {
        for event in events { try apply(event) }
    }

    /// Every steward, sorted by id.
    public var all: [StewardRecord] { records.values.sorted { $0.id < $1.id } }

    /// Applies one event; events of other types are ignored.
    public mutating func apply(_ event: RuntimeEvent) throws {
        guard let id = event.draft.steward else { return }
        switch event.type {
        case StewardEventType.created:
            let body = try Payload.decode(CharterPayload.self, event.payload)
            records[id] = StewardRecord(
                id: id, charter: body.charter, version: body.version, status: .active,
                ready: false, createdAt: event.at)
        case StewardEventType.charterUpdated:
            let body = try Payload.decode(CharterPayload.self, event.payload)
            records[id]?.charter = body.charter
            records[id]?.version = body.version
        case StewardEventType.ready: records[id]?.ready = true
        case StewardEventType.paused: records[id]?.status = .paused
        case StewardEventType.resumed: records[id]?.status = .active
        case StewardEventType.retired: records[id]?.status = .retired
        default: return
        }
    }
}

/// Creates and changes stewards by appending events.
public struct StewardLifecycle: Sendable {
    private let sink: any EventSink

    /// Creates a lifecycle over a sink.
    public init(sink: any EventSink) {
        self.sink = sink
    }

    /// The current book.
    public func book() async throws -> StewardBook {
        try StewardBook(try await sink.events(from: 1))
    }

    /// Records `steward.created` with the charter at version 1.
    @discardableResult
    public func create(_ charter: Charter, by actor: RuntimeActor = .localUser)
        async throws -> StewardRecord
    {
        try check(charter)
        guard try await book().records[charter.id] == nil else {
            throw StewardError.alreadyExists(charter.id)
        }
        let payload = CharterPayload(charter: charter, version: 1, reason: nil)
        return try await record(StewardEventType.created, charter.id, actor, payload)
    }

    /// Records `steward.charter.updated` with the version increased by one.
    @discardableResult
    public func updateCharter(
        _ charter: Charter, reason: String? = nil, by actor: RuntimeActor = .localUser
    ) async throws -> StewardRecord {
        try check(charter)
        let current = try await existing(charter.id)
        guard current.status != .retired else {
            throw StewardError.wrongStatus(current.id, current.status)
        }
        let payload = CharterPayload(charter: charter, version: current.version + 1, reason: reason)
        return try await record(StewardEventType.charterUpdated, charter.id, actor, payload)
    }

    /// Pauses an active steward.
    @discardableResult
    public func pause(_ id: StewardID, reason: String? = nil, by actor: RuntimeActor = .localUser)
        async throws -> StewardRecord
    {
        try await transition(id, from: [.active], type: StewardEventType.paused, reason, actor)
    }

    /// Resumes a paused steward.
    @discardableResult
    public func resume(_ id: StewardID, by actor: RuntimeActor = .localUser)
        async throws -> StewardRecord
    {
        try await transition(id, from: [.paused], type: StewardEventType.resumed, nil, actor)
    }

    /// Retires an active or paused steward.
    @discardableResult
    public func retire(_ id: StewardID, reason: String? = nil, by actor: RuntimeActor = .localUser)
        async throws -> StewardRecord
    {
        try await transition(
            id, from: [.active, .paused], type: StewardEventType.retired, reason, actor)
    }

    private func check(_ charter: Charter) throws {
        let issues = charter.validate()
        if !issues.isEmpty { throw StewardError.invalidCharter(issues) }
    }

    private func existing(_ id: StewardID) async throws -> StewardRecord {
        guard let current = try await book().records[id] else { throw StewardError.notFound(id) }
        return current
    }

    private func transition(
        _ id: StewardID, from allowed: Set<StewardStatus>, type: String, _ reason: String?,
        _ actor: RuntimeActor
    ) async throws -> StewardRecord {
        let current = try await existing(id)
        guard allowed.contains(current.status) else {
            throw StewardError.wrongStatus(id, current.status)
        }
        return try await record(type, id, actor, ReasonPayload(reason: reason))
    }

    private func record(
        _ type: String, _ id: StewardID, _ actor: RuntimeActor, _ payload: some Encodable
    ) async throws -> StewardRecord {
        _ = try await sink.append(
            RuntimeEventDraft(
                type: type, steward: id, actor: actor, payload: try Payload.encode(payload)))
        return try await existing(id)
    }
}
