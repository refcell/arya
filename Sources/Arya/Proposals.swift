import AryaCore
import AryaEval
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation

// Gated changes (decision 0025): charter proposals through `ProposalDesk` + `RehearsalGate`,
// routine versions through `RoutineGatekeeper` + `RoutineRehearsalGate`. A change goes live
// only when its rehearsal gate passes or a person overrides it.

/// A gate's verdict.
public struct GateVerdictSummary: Sendable, Hashable, Codable {
    public var passed: Bool
    public var baselineMean: Double?
    public var candidateMean: Double
    /// Cases that passed on the baseline and fail on the candidate.
    public var regressions: [String]
    public var reason: String
}

/// A charter proposal.
public struct ProposalSummary: Sendable, Hashable, Codable {
    public var id: String
    public var steward: String
    /// The live version it was written against, and the version it becomes.
    public var baseVersion: Int
    public var candidateVersion: Int
    public var reason: String?
    /// `human:local`, `steward:st_…`, ...
    public var author: String
    /// `open`, `passed`, `failed`, `overridden`, `accepted`, or `rejected`.
    public var status: String
    public var verdict: GateVerdictSummary?
    /// True when `acceptProposal` would make it live (passed or overridden).
    public var acceptable: Bool
    /// What it changes against the live charter, as a set: `outcome`, `metric`, `guardrails`,
    /// `signoff`, `adapter`. Empty when it changes none of these (or the steward is gone).
    public var impact: [String] = []
    /// Guardrails and sign-offs it removes or loosens, in plain words.
    public var removed: [String] = []
    /// The full impact, with the sentences an approver reads and `needsConfirm`.
    public var detail: ProposalImpact?
}

/// The outcome of gating a routine version.
public struct RoutineGateSummary: Sendable, Hashable, Codable {
    /// Proposal id the gate recorded (`proposal.gated` with the routine).
    public var proposal: String
    public var verdict: GateVerdictSummary
    /// True when the version went live (`routine.promoted`).
    public var promoted: Bool
}

extension Workspace {
    // MARK: Charter proposals

    /// Records a proposed charter (`proposal.created`). Refused when `baseVersion` is no
    /// longer the live version (someone changed the charter since the draft started). A title
    /// is kept as the first line of the reason.
    public func proposeCharter(
        steward: String, charter: Data, baseVersion: Int, title: String? = nil,
        reason: String? = nil, by person: String = "local"
    ) async throws -> ProposalSummary {
        let live = try await existing(steward)
        let parsed: Charter
        do {
            parsed = try Charter.load(from: charter)
        } catch let error as CharterError {
            throw WorkspaceError.rejected(Self.describe(error))
        }
        guard parsed.id == live.id else {
            throw WorkspaceError.rejected(
                "charter is for \(parsed.id.rawValue), not \(live.id.rawValue)")
        }
        guard baseVersion == live.version else {
            throw WorkspaceError.rejected(
                "draft started from version \(baseVersion); version \(live.version) is live")
        }
        let text = [title, reason].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        let record = try await proposing {
            try await desk.propose(parsed, reason: text.isEmpty ? nil : text, by: .person(person))
        }
        return try await measured([record])[0]
    }

    /// A steward's charter proposals, newest first.
    public func proposals(steward: String) async throws -> [ProposalSummary] {
        let id = try await existing(steward).id
        return try await measured(
            ProposalBook(try facadeState().runtime).all(steward: id).reversed())
    }

    /// One proposal, or `nil`.
    public func proposal(_ id: String) async throws -> ProposalSummary? {
        guard
            let record = try ProposalBook(try facadeState().runtime)
                .records[ProposalID(unchecked: id)]
        else { return nil }
        return try await measured([record]).first
    }

    /// Summaries with their impact against the charter each was written against (its base
    /// version), so a decided proposal keeps showing what it changed.
    func measured(_ records: [ProposalRecord]) async throws -> [ProposalSummary] {
        var book = StewardBook()
        var versions: [StewardID: [Int: Charter]] = [:]
        for event in try facadeState().runtime {
            try book.apply(event)
            guard let steward = event.draft.steward, let record = book.records[steward]
            else { continue }
            versions[steward, default: [:]][record.version] = record.charter
        }
        return records.map { record in
            var summary = ProposalSummary(record)
            let base =
                versions[record.steward]?[record.baseVersion]
                ?? book.records[record.steward]?.charter
            summary.measure(record.charter, against: base)
            return summary
        }
    }

    /// Runs the rehearsal gate on a casebook version (default: the steward's newest), which
    /// records `proposal.gated`, and returns the updated proposal.
    public func checkProposal(_ id: String, casebook version: String? = nil) async throws
        -> ProposalSummary
    {
        let found = try await requireProposal(id)
        let book = try await casebook(for: found.steward, version: version)
        _ = try await proposing {
            try await desk.check(ProposalID(unchecked: id), casebookVersion: book.version)
        }
        return try await requireProposal(id)
    }

    /// Makes a passed or overridden proposal live (`steward.charter.updated`, then
    /// `proposal.accepted`).
    public func acceptProposal(_ id: String, by person: String = "local") async throws
        -> StewardSummary
    {
        let record = try await proposing {
            try await desk.accept(ProposalID(unchecked: id), by: .person(person))
        }
        return StewardSummary(record)
    }

    /// Closes a proposal without making it live (`proposal.rejected`).
    public func rejectProposal(_ id: String, reason: String? = nil, by person: String = "local")
        async throws
    {
        try await proposing {
            try await desk.reject(ProposalID(unchecked: id), reason: reason, by: .person(person))
        }
    }

    /// A person accepts responsibility for a failed gate (`proposal.overridden`); the proposal
    /// then becomes acceptable.
    public func overrideProposal(_ id: String, reason: String, by person: String = "local")
        async throws
    {
        guard !reason.isEmpty else { throw WorkspaceError.rejected("an override needs a reason") }
        try await proposing {
            try await desk.override(ProposalID(unchecked: id), reason: reason, person: person)
        }
    }

    // MARK: Routine gates

    /// Gates a proposed routine version: rehearses the live charter with the version in place
    /// of the live one on a casebook (default: the steward's newest) and promotes it
    /// (`routine.promoted`) only when the gate passes.
    public func gateRoutine(
        steward: String, name: String, version: String, casebook: String? = nil
    ) async throws -> RoutineGateSummary {
        let id = try await existing(steward).id
        let book = try await self.casebook(for: steward, version: casebook)
        let proposal = ambient.newID(ProposalID.self)
        let library = try RoutineLibrary(ledger: try facadeState().events)
        let outcome = try await routinePromoting {
            try await RoutineGatekeeper(
                gate: RoutineRehearsalGate(sink: sink, rehearser: rehearser)
            ).check(
                steward: id, name: name, version: version, proposal: proposal,
                casebookVersion: book.version, library: library)
        }
        if let promotion = outcome.promotion {
            _ = try await sink.append(RuntimeEventDraft(promotion))
        }
        return RoutineGateSummary(
            proposal: proposal.rawValue, verdict: GateVerdictSummary(outcome.verdict),
            promoted: outcome.promotion != nil)
    }

    /// A person promotes a routine version without (or despite) its gate: `routine.promoted`
    /// with the person as actor, then `proposal.overridden` carrying the required reason.
    public func overrideRoutine(
        steward: String, name: String, version: String, reason: String,
        by person: String = "local"
    ) async throws {
        guard !reason.isEmpty else { throw WorkspaceError.rejected("an override needs a reason") }
        let id = try await existing(steward).id
        let library = try RoutineLibrary(ledger: try facadeState().events)
        let proposal = ambient.newID(ProposalID.self)
        let draft = try await routinePromoting {
            try RoutineGatekeeper.override(
                steward: id, name: name, version: version, proposal: proposal,
                person: Actor(kind: .human, id: person), library: library)
        }
        _ = try await sink.append(RuntimeEventDraft(draft))
        _ = try await sink.append(
            RuntimeEventDraft(
                type: ProposalEventType.overridden, steward: id, actor: .person(person),
                payload: [
                    "v": 1, "proposal": .string(proposal.rawValue), "reason": .string(reason),
                ]))
    }

    // MARK: Helpers

    var desk: ProposalDesk {
        ProposalDesk(
            sink: sink, gate: RehearsalGate(sink: sink, rehearser: rehearser), ambient: ambient)
    }

    private func requireProposal(_ id: String) async throws -> ProposalSummary {
        guard let found = try await proposal(id) else { throw WorkspaceError.notFound(id) }
        return found
    }

    /// Runs `body`, turning proposal and steward errors into facade errors.
    private func proposing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await mapped(body)
        } catch let error as ProposalError {
            throw Self.facadeError(error)
        }
    }

    private func routinePromoting<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await mapped(body)
        } catch let error as RoutinePromotionError {
            throw WorkspaceError.rejected("\(error)")
        }
    }

    static func facadeError(_ error: ProposalError) -> WorkspaceError {
        switch error {
        case .notFound(let id): .notFound(id.rawValue)
        case .stewardMismatch(let expected, let got):
            .rejected("proposal is for \(got.rawValue), not \(expected.rawValue)")
        case .notAcceptable(let id, let status):
            .rejected("\(id.rawValue) is \(status.rawValue); its gate must pass or be overridden")
        case .stale(let id, let base, let live):
            .rejected("\(id.rawValue) was written against version \(base); \(live) is live")
        case .notOverridable(let id, let status):
            .rejected("\(id.rawValue) is \(status.rawValue); only a failed gate can be overridden")
        case .closed(let id, let status): .rejected("\(id.rawValue) is already \(status.rawValue)")
        }
    }
}

extension GateVerdictSummary {
    init(_ verdict: GateCheckVerdict) {
        self.init(
            passed: verdict.passed, baselineMean: verdict.baselineMean,
            candidateMean: verdict.candidateMean, regressions: verdict.regressions.map(\.rawValue),
            reason: verdict.reason)
    }
}

extension ProposalSummary {
    init(_ record: ProposalRecord) {
        self.init(
            id: record.id.rawValue, steward: record.steward.rawValue,
            baseVersion: record.baseVersion, candidateVersion: record.candidateVersion,
            reason: record.reason, author: "\(record.author.kind):\(record.author.id)",
            status: record.status.rawValue, verdict: record.verdict.map(GateVerdictSummary.init),
            acceptable: record.acceptable)
    }
}
