import AryaCore
import AryaRuntime

/// Ledger event types of proposals.
public enum ProposalEventType {
    public static let created = "proposal.created"
    public static let gated = "proposal.gated"
    public static let accepted = "proposal.accepted"
    public static let rejected = "proposal.rejected"
    public static let overridden = "proposal.overridden"
}

/// Payload of `proposal.created`: a candidate charter for a steward.
public struct ProposalCreatedPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var proposal: ProposalID
    public var kind: String = "charter"
    public var charter: Charter
    /// The live version the candidate was written against.
    public var baseVersion: Int
    public var candidateVersion: Int
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case v, proposal, kind, charter, baseVersion, candidateVersion, reason
    }
}

/// Payload of `proposal.gated`.
public struct ProposalGatedPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var proposal: ProposalID
    public var casebook: String
    public var baseline: RehearsalID?
    public var candidate: RehearsalID?
    public var verdict: GateCheckVerdict

    enum CodingKeys: String, CodingKey {
        case v, proposal, casebook, baseline, candidate, verdict
    }
}

/// Payload of `proposal.accepted`, `proposal.rejected`, and `proposal.overridden`.
public struct ProposalDecisionPayload: Hashable, Sendable, Codable {
    public var v: Int = 1
    public var proposal: ProposalID
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case v, proposal, reason
    }
}

public enum ProposalStatus: String, Hashable, Sendable, Codable {
    case open, passed, failed, overridden, accepted, rejected
}

/// One proposal as projected from the ledger.
public struct ProposalRecord: Hashable, Sendable {
    public var id: ProposalID
    public var steward: StewardID
    public var charter: Charter
    public var baseVersion: Int
    public var candidateVersion: Int
    public var reason: String?
    public var author: RuntimeActor
    public var status: ProposalStatus
    public var verdict: GateCheckVerdict?

    /// True when a person may accept it: its gate passed or a person overrode a failed gate.
    public var acceptable: Bool { status == .passed || status == .overridden }
}

/// Folds `proposal.*` events into records.
public struct ProposalBook: Sendable {
    public private(set) var records: [ProposalID: ProposalRecord] = [:]

    public init() {}

    public init(_ events: [RuntimeEvent]) throws {
        for event in events { try apply(event) }
    }

    /// Proposals of a steward, oldest id first.
    public func all(steward: StewardID) -> [ProposalRecord] {
        records.values.filter { $0.steward == steward }.sorted { $0.id < $1.id }
    }

    public mutating func apply(_ event: RuntimeEvent) throws {
        switch event.type {
        case ProposalEventType.created:
            guard let steward = event.draft.steward else { return }
            let body = try EvalPayload.decode(ProposalCreatedPayload.self, event.payload)
            records[body.proposal] = ProposalRecord(
                id: body.proposal, steward: steward, charter: body.charter,
                baseVersion: body.baseVersion, candidateVersion: body.candidateVersion,
                reason: body.reason, author: event.draft.actor, status: .open, verdict: nil)
        case ProposalEventType.gated:
            let body = try EvalPayload.decode(ProposalGatedPayload.self, event.payload)
            guard var record = records[body.proposal], !record.isClosed else { return }
            record.verdict = body.verdict
            record.status = body.verdict.passed ? .passed : .failed
            records[body.proposal] = record
        case ProposalEventType.accepted: try decide(event, .accepted)
        case ProposalEventType.rejected: try decide(event, .rejected)
        case ProposalEventType.overridden: try decide(event, .overridden)
        default: return
        }
    }

    private mutating func decide(_ event: RuntimeEvent, _ status: ProposalStatus) throws {
        let body = try EvalPayload.decode(ProposalDecisionPayload.self, event.payload)
        records[body.proposal]?.status = status
    }
}

extension ProposalRecord {
    var isClosed: Bool { status == .accepted || status == .rejected }
}

/// Why a proposal operation was refused.
public enum ProposalError: Error, Equatable, Sendable {
    case notFound(ProposalID)
    case stewardMismatch(expected: StewardID, got: StewardID)
    /// The gate has not passed and no person overrode it.
    case notAcceptable(ProposalID, ProposalStatus)
    /// The live charter changed since the proposal was written; propose again.
    case stale(ProposalID, baseVersion: Int, liveVersion: Int)
    /// Only a failed gate can be overridden.
    case notOverridable(ProposalID, ProposalStatus)
    case closed(ProposalID, ProposalStatus)
}

/// Creates, gates, and decides proposals. Charter changes go live only through `accept`.
public struct ProposalDesk: Sendable {
    public var sink: any EventSink
    public var gate: any GateChecking
    public var ambient: Ambient

    public init(sink: any EventSink, gate: any GateChecking, ambient: Ambient) {
        self.sink = sink
        self.gate = gate
        self.ambient = ambient
    }

    /// Records `proposal.created` for a candidate charter of an existing steward.
    @discardableResult
    public func propose(
        _ charter: Charter, reason: String? = nil, by actor: RuntimeActor = .localUser
    ) async throws -> ProposalRecord {
        let issues = charter.validate()
        guard issues.isEmpty else { throw StewardError.invalidCharter(issues) }
        let live = try await liveRecord(charter.id)
        let id = ambient.newID(ProposalID.self)
        let payload = ProposalCreatedPayload(
            proposal: id, charter: charter, baseVersion: live.version,
            candidateVersion: live.version + 1, reason: reason)
        try await append(ProposalEventType.created, charter.id, actor, payload)
        return try await record(id)
    }

    /// Runs the gate on a casebook version. The gate records `proposal.gated`.
    public func check(_ id: ProposalID, casebookVersion: String) async throws -> GateCheckVerdict {
        let proposal = try await open(id)
        return try await gate.check(
            GateCheckRequest(
                steward: proposal.steward, proposal: id,
                candidateVersion: proposal.candidateVersion, casebookVersion: casebookVersion))
    }

    /// A person overrides a failed gate (`proposal.overridden`, the person as actor).
    public func override(_ id: ProposalID, reason: String, person: String) async throws {
        let proposal = try await open(id)
        guard proposal.status == .failed else {
            throw ProposalError.notOverridable(id, proposal.status)
        }
        try await append(
            ProposalEventType.overridden, proposal.steward, .person(person),
            ProposalDecisionPayload(proposal: id, reason: reason))
    }

    /// Makes the candidate live: `steward.charter.updated`, then `proposal.accepted`.
    @discardableResult
    public func accept(
        _ id: ProposalID, by actor: RuntimeActor = .localUser
    ) async throws -> StewardRecord {
        let proposal = try await open(id)
        guard proposal.acceptable else { throw ProposalError.notAcceptable(id, proposal.status) }
        let live = try await liveRecord(proposal.steward)
        guard live.version == proposal.baseVersion else {
            throw ProposalError.stale(
                id, baseVersion: proposal.baseVersion, liveVersion: live.version)
        }
        let updated = try await StewardLifecycle(sink: sink).updateCharter(
            proposal.charter, reason: "proposal \(id.rawValue)", by: actor)
        try await append(
            ProposalEventType.accepted, proposal.steward, actor,
            ProposalDecisionPayload(proposal: id, reason: nil))
        return updated
    }

    public func reject(
        _ id: ProposalID, reason: String? = nil, by actor: RuntimeActor = .localUser
    ) async throws {
        let proposal = try await open(id)
        try await append(
            ProposalEventType.rejected, proposal.steward, actor,
            ProposalDecisionPayload(proposal: id, reason: reason))
    }

    public func record(_ id: ProposalID) async throws -> ProposalRecord {
        guard let record = try ProposalBook(try await sink.events(from: 1)).records[id] else {
            throw ProposalError.notFound(id)
        }
        return record
    }

    private func open(_ id: ProposalID) async throws -> ProposalRecord {
        let record = try await record(id)
        guard !record.isClosed else { throw ProposalError.closed(id, record.status) }
        return record
    }

    private func liveRecord(_ id: StewardID) async throws -> StewardRecord {
        guard let live = try StewardBook(try await sink.events(from: 1)).records[id] else {
            throw StewardError.notFound(id)
        }
        return live
    }

    private func append(
        _ type: String, _ steward: StewardID, _ actor: RuntimeActor, _ payload: some Encodable
    ) async throws {
        _ = try await sink.append(
            RuntimeEventDraft(
                type: type, steward: steward, actor: actor,
                payload: try CanonicalJSON.jsonValue(payload)))
    }
}
