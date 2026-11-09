import AryaCore
import AryaLedger
import Foundation
import Testing

@testable import AryaMemory

/// A gate that passes or fails as told and records each request.
final class ScriptedGate: RoutineGateChecking, @unchecked Sendable {
    let passes: Bool
    private let lock = NSLock()
    private var seen: [RoutineGateRequest] = []

    init(passes: Bool) { self.passes = passes }

    var requests: [RoutineGateRequest] { lock.withLock { seen } }

    func check(_ request: RoutineGateRequest) async throws -> GateCheckVerdict {
        lock.withLock { seen.append(request) }
        return GateCheckVerdict(
            passed: passes, baselineMean: 0.8, candidateMean: passes ? 0.9 : 0.5,
            regressions: passes ? [] : ["case-0002"], reason: passes ? "ok" : "regressed")
    }
}

@Suite struct RoutineProposalsTests {
    @Test func intakeStoresContentAndDraftsProposals() throws {
        let store = InMemoryRoutineBlobStore()
        let intake = try RoutineProposals.intake(
            [
                ProposedRoutine(
                    name: "label-issue", language: "sh", content: labelV1,
                    reason: "Repeated in 5 runs."),
                ProposedRoutine(name: "Bad Name", language: "sh", content: "echo"),
                ProposedRoutine(name: "x", language: "python", content: "print()"),
                ProposedRoutine(name: "label-issue", language: "sh", content: labelV2),
            ],
            steward: "st_triage", run: "run_1", library: RoutineLibrary(), store: store)
        #expect(intake.accepted.map(\.name) == ["label-issue"])
        #expect(intake.rejected.map(\.name) == ["Bad Name", "x", "label-issue"])
        #expect(
            intake.rejected.map(\.error) == [
                .invalidName("Bad Name"), .unknownLanguage("python"), .duplicateName("label-issue"),
            ])
        let draft = try #require(intake.drafts.first)
        #expect(draft.type == .routineProposed)
        #expect(draft.actor == .steward("st_triage"))
        #expect(draft.run == "run_1")
        let version = intake.accepted[0].version
        #expect(try store.get(version) == Data(labelV1.utf8))
    }

    @Test func intakeSkipsVersionsAlreadyProposed() throws {
        let store = InMemoryRoutineBlobStore()
        let source = try RoutineSource(name: "label-issue", language: .sh, content: labelV1)
        let library = try RoutineLibrary(events: [
            routineEvent(seq: 1, type: RoutineEventType.proposed, try source.propose(into: store))
        ])
        let intake = try RoutineProposals.intake(
            [ProposedRoutine(name: "label-issue", language: "sh", content: labelV1)],
            steward: "st_triage", run: nil, library: library, store: store)
        #expect(intake.drafts.isEmpty)
        #expect(intake.unchanged == ["label-issue"])
    }
}

@Suite struct RoutineGatekeeperTests {
    /// v1 live, v2 pending.
    func library() throws -> RoutineLibrary {
        let v1 = try RoutineSource(name: "label-issue", language: .sh, content: labelV1)
        let v2 = try RoutineSource(name: "label-issue", language: .sh, content: labelV2)
        let other = try RoutineSource(name: "digest", language: .prompt, content: "Summarize.")
        let p = RoutineEventType.self
        return try RoutineLibrary(events: [
            routineEvent(seq: 1, type: p.proposed, RoutineProposedPayload(source: v1)),
            routineEvent(
                seq: 2, type: p.promoted,
                RoutinePromotedPayload(name: v1.name, version: v1.version)),
            routineEvent(seq: 3, type: p.proposed, RoutineProposedPayload(source: other)),
            routineEvent(
                seq: 4, type: p.promoted,
                RoutinePromotedPayload(name: other.name, version: other.version)),
            routineEvent(seq: 5, type: p.proposed, RoutineProposedPayload(source: v2)),
        ])
    }

    var v1: String { RoutineNaming.version(of: Data(labelV1.utf8)) }
    var v2: String { RoutineNaming.version(of: Data(labelV2.utf8)) }

    @Test func passingGatePromotesAsSystem() async throws {
        let gate = ScriptedGate(passes: true)
        let library = try library()
        let outcome = try await RoutineGatekeeper(gate: gate).check(
            steward: "st_triage", name: "label-issue", version: v2,
            proposal: ProposalID(body: "7")!, casebookVersion: "cb1", library: library)
        #expect(
            gate.requests == [
                RoutineGateRequest(
                    steward: "st_triage", proposal: ProposalID(body: "7")!, name: "label-issue",
                    candidateVersion: v2, liveVersion: v1, casebookVersion: "cb1")
            ])
        let promotion = try #require(outcome.promotion)
        #expect(promotion.actor == .system)
        var next = library
        try next.apply(
            routineEvent(
                seq: 6, type: RoutineEventType.promoted,
                try CanonicalJSON.decode(
                    RoutinePromotedPayload.self, from: CanonicalJSON.encode(promotion.payload))))
        #expect(next.live(steward: "st_triage", name: "label-issue")?.version == v2)
    }

    @Test func failingGateLeavesTheProposalPending() async throws {
        let outcome = try await RoutineGatekeeper(gate: ScriptedGate(passes: false)).check(
            steward: "st_triage", name: "label-issue", version: v2,
            proposal: ProposalID(body: "7")!, casebookVersion: "cb1", library: try library())
        #expect(outcome.promotion == nil)
        #expect(outcome.verdict.regressions == ["case-0002"])
    }

    @Test func defaultGateRefuses() async throws {
        let outcome = try await RoutineGatekeeper().check(
            steward: "st_triage", name: "label-issue", version: v2,
            proposal: ProposalID(body: "7")!, casebookVersion: "cb1", library: try library())
        #expect(outcome.promotion == nil)
        #expect(outcome.verdict.reason == "no routine gate configured")
    }

    @Test func refusesUnknownAndLiveVersions() throws {
        let library = try library()
        let proposal = ProposalID(body: "7")!
        #expect(throws: RoutinePromotionError.alreadyLive(name: "label-issue", version: v1)) {
            try RoutineGatekeeper.request(
                steward: "st_triage", name: "label-issue", version: v1, proposal: proposal,
                casebookVersion: "cb1", library: library)
        }
        #expect(throws: RoutinePromotionError.unknownVersion(name: "label-issue", version: "f")) {
            try RoutineGatekeeper.request(
                steward: "st_triage", name: "label-issue", version: "f", proposal: proposal,
                casebookVersion: "cb1", library: library)
        }
    }

    @Test func overrideRequiresAPerson() throws {
        let library = try library()
        let proposal = ProposalID(body: "7")!
        let draft = try RoutineGatekeeper.override(
            steward: "st_triage", name: "label-issue", version: v2, proposal: proposal,
            person: .local, library: library)
        #expect(draft.actor == .local)
        #expect(throws: RoutinePromotionError.notAPerson("arya")) {
            try RoutineGatekeeper.override(
                steward: "st_triage", name: "label-issue", version: v2, proposal: proposal,
                person: .system, library: library)
        }
    }

    @Test func candidateRoutinesSwapInTheCandidate() throws {
        let library = try library()
        let request = try RoutineGatekeeper.request(
            steward: "st_triage", name: "label-issue", version: v2,
            proposal: ProposalID(body: "7")!, casebookVersion: "cb1", library: library)
        let set = library.candidateRoutines(for: request)
        #expect(set.map(\.name) == ["digest", "label-issue"])
        #expect(set.last?.version == v2)
    }
}
