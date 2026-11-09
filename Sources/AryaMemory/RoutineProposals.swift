import AryaCore
import AryaLedger
import Foundation

/// A routine as a run's `run/result` proposes it (`routines[]` in PROTOCOL.md). The runtime
/// converts the adapter's type into this one, so memory does not depend on adapters.
public struct ProposedRoutine: Sendable, Equatable {
    public var name: String
    public var language: String
    public var content: String
    public var reason: String?

    public init(name: String, language: String, content: String, reason: String? = nil) {
        self.name = name
        self.language = language
        self.content = content
        self.reason = reason
    }
}

/// What intake did with each proposed routine.
public struct RoutineIntake: Sendable {
    /// One `routine.proposed` draft per accepted routine, in result order.
    public var drafts: [EventDraft]
    public var accepted: [RoutineProposedPayload]
    /// Routines that failed validation, with why; recorded by the caller (for example in the
    /// run's summary), never proposed.
    public var rejected: [(name: String, error: RoutineError)]
    /// Names whose content equals the live version or an earlier proposal of that version.
    public var unchanged: [String]
}

/// Turns a run's proposed routines into `routine.proposed` events. Content goes into the blob
/// store first, so an event never names a missing blob.
public enum RoutineProposals {
    public static func intake(
        _ routines: [ProposedRoutine], steward: StewardID, run: RunID?,
        library: RoutineLibrary, store: some RoutineBlobStore
    ) throws -> RoutineIntake {
        var intake = RoutineIntake(drafts: [], accepted: [], rejected: [], unchanged: [])
        var seenNames = Set<String>()
        for routine in routines {
            let source: RoutineSource
            do {
                source = try RoutineSource(
                    name: routine.name, language: routine.language, content: routine.content)
            } catch {
                intake.rejected.append((routine.name, error))
                continue
            }
            guard seenNames.insert(source.name).inserted else {
                intake.rejected.append((routine.name, .duplicateName(routine.name)))
                continue
            }
            if library.version(steward: steward, name: source.name, version: source.version)
                != nil
            {
                intake.unchanged.append(source.name)
                continue
            }
            let payload = try source.propose(into: store, reason: routine.reason, run: run)
            intake.accepted.append(payload)
            intake.drafts.append(
                try EventDraft(payload, actor: .steward(steward), steward: steward, run: run))
        }
        return intake
    }
}

/// A gate check for a routine version: rehearse the steward's live charter with `candidate`
/// in place of the live version of its name (or added, for a new name), on a casebook version,
/// and compare with the baseline.
public struct RoutineGateRequest: Hashable, Sendable, Codable {
    public var steward: StewardID
    public var proposal: ProposalID
    public var name: String
    public var candidateVersion: String
    /// The live version being replaced; nil for a new routine.
    public var liveVersion: String?
    public var casebookVersion: String

    public init(
        steward: StewardID, proposal: ProposalID, name: String, candidateVersion: String,
        liveVersion: String?, casebookVersion: String
    ) {
        self.steward = steward
        self.proposal = proposal
        self.name = name
        self.candidateVersion = candidateVersion
        self.liveVersion = liveVersion
        self.casebookVersion = casebookVersion
    }

    private enum CodingKeys: String, CodingKey {
        case steward, proposal, name, candidateVersion, liveVersion, casebookVersion
    }
}

/// Checks routine proposals. `Arya` wires it to `AryaEval`, as it wires `GateChecking` for
/// charters; `RefusingRoutineGate` is the safe default.
public protocol RoutineGateChecking: Sendable {
    func check(_ request: RoutineGateRequest) async throws -> GateCheckVerdict
}

/// Refuses every routine proposal.
public struct RefusingRoutineGate: RoutineGateChecking {
    public init() {}

    public func check(_ request: RoutineGateRequest) async throws -> GateCheckVerdict {
        GateCheckVerdict(
            passed: false, baselineMean: nil, candidateMean: 0, regressions: [],
            reason: "no routine gate configured")
    }
}

/// Reasons a routine version cannot be gated or promoted.
public enum RoutinePromotionError: Error, Equatable, Sendable {
    case unknownVersion(name: String, version: String)
    case alreadyLive(name: String, version: String)
    case notAPerson(String)
}

/// The result of gating one routine version.
public struct RoutineGateOutcome: Sendable {
    public var request: RoutineGateRequest
    public var verdict: GateCheckVerdict
    /// The `routine.promoted` draft (actor `system`) when the gate passed; nil otherwise. A
    /// failed proposal stays pending until a person overrides it or a newer version replaces
    /// it.
    public var promotion: EventDraft?
}

/// Gates routine versions and builds their promotions. Routines go live only through here.
public struct RoutineGatekeeper: Sendable {
    public var gate: any RoutineGateChecking

    public init(gate: any RoutineGateChecking = RefusingRoutineGate()) {
        self.gate = gate
    }

    /// The gate request for a pending version.
    public static func request(
        steward: StewardID, name: String, version: String, proposal: ProposalID,
        casebookVersion: String, library: RoutineLibrary
    ) throws(RoutinePromotionError) -> RoutineGateRequest {
        guard library.version(steward: steward, name: name, version: version) != nil else {
            throw .unknownVersion(name: name, version: version)
        }
        let live = library.live(steward: steward, name: name)?.version
        guard live != version else { throw .alreadyLive(name: name, version: version) }
        return RoutineGateRequest(
            steward: steward, proposal: proposal, name: name, candidateVersion: version,
            liveVersion: live, casebookVersion: casebookVersion)
    }

    /// Checks a pending version and returns the verdict and, if it passed, the promotion.
    public func check(
        steward: StewardID, name: String, version: String, proposal: ProposalID,
        casebookVersion: String, library: RoutineLibrary
    ) async throws -> RoutineGateOutcome {
        let request = try Self.request(
            steward: steward, name: name, version: version, proposal: proposal,
            casebookVersion: casebookVersion, library: library)
        let verdict = try await gate.check(request)
        let promotion =
            verdict.passed
            ? try EventDraft(
                RoutinePromotedPayload(name: name, version: version, proposal: proposal),
                actor: .system, steward: steward)
            : nil
        return RoutineGateOutcome(request: request, verdict: verdict, promotion: promotion)
    }

    /// A person promotes a version whose gate failed (recorded with the person as actor, next
    /// to the proposal's `proposal.overridden`).
    public static func override(
        steward: StewardID, name: String, version: String, proposal: ProposalID,
        person: Actor, library: RoutineLibrary
    ) throws -> EventDraft {
        guard person.kind == .human else { throw RoutinePromotionError.notAPerson(person.id) }
        guard library.version(steward: steward, name: name, version: version) != nil else {
            throw RoutinePromotionError.unknownVersion(name: name, version: version)
        }
        return try EventDraft(
            RoutinePromotedPayload(name: name, version: version, proposal: proposal),
            actor: person, steward: steward)
    }
}

extension RoutineLibrary {
    /// The routines a rehearsal of `request` sees: the live set with the candidate in place.
    public func candidateRoutines(for request: RoutineGateRequest) -> [RoutineVersion] {
        var set = liveRoutines(steward: request.steward).filter { $0.name != request.name }
        if let candidate = version(
            steward: request.steward, name: request.name, version: request.candidateVersion)
        {
            set.append(candidate)
        }
        return set.sorted { $0.name < $1.name }
    }
}
