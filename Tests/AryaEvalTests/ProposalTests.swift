import AryaCore
import AryaMemory
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

/// Answers "bug" for every case, except that a charter whose first guardrail is `sloppy`
/// answers "feature" for `c-1`, and one whose first guardrail is `better` answers "bug"
/// even for `c-4` (which the live charter gets wrong).
struct CharterRunner: CaseRunner {
    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let mode = request.routine.map { $0.version } ?? request.charter.guardrails.first ?? ""
        let id = request.caseItem.id.rawValue
        var choice = "bug"
        if mode == "sloppy" && id == "c-1" { choice = "feature" }
        if mode != "better" && id == "c-4" { choice = "unsure" }
        return CaseRunOutcome(run: nil, result: ["decisions": [["choice": .string(choice)]]])
    }
}

private struct Harness {
    let sink = MemoryEventSink(ambient: .fixed())
    let ambient = Ambient.fixed(seed: 3)
    let book: Casebook
    let desk: ProposalDesk
    let routineGate: RoutineRehearsalGate
    let steward = StewardID(unchecked: "st_triage")

    init(tolerance: Double = 0) throws {
        book = try Casebook(
            name: "triage",
            cases: ["c-1", "c-2", "c-3", "c-4"].map {
                Case(
                    id: CaseID(rawValue: $0)!, input: CaseInput(text: "issue"),
                    expected: ["decisions": [["choice": "bug"]]])
            })
        let rehearser = CasebookRehearser(
            runner: CharterRunner(), casebooks: FixedCasebooks(book: book), sink: sink,
            ambient: ambient)
        routineGate = RoutineRehearsalGate(sink: sink, rehearser: rehearser)
        desk = ProposalDesk(
            sink: sink, gate: RehearsalGate(sink: sink, rehearser: rehearser), ambient: ambient)
        self.tolerance = tolerance
    }

    let tolerance: Double

    func charter(_ guardrail: String) -> Charter {
        var charter = testCharter
        charter.guardrails = [guardrail]
        charter.gate = GateConfig(samples: 1, tolerance: tolerance)
        return charter
    }

    func start() async throws {
        try await StewardLifecycle(sink: sink).create(charter("plain"))
    }

    func types() async throws -> [String] {
        try await sink.events(from: 1).map(\.type)
    }
}

@Test func passingProposalGoesLiveOnlyAfterAccept() async throws {
    let h = try Harness()
    try await h.start()
    let proposal = try await h.desk.propose(h.charter("better"), reason: "handle unsure cases")
    #expect(proposal.status == .open)
    #expect(proposal.candidateVersion == 2)
    await #expect(throws: ProposalError.notAcceptable(proposal.id, .open)) {
        try await h.desk.accept(proposal.id)
    }

    let verdict = try await h.desk.check(proposal.id, casebookVersion: h.book.version)
    #expect(verdict.passed)
    #expect(verdict.baselineMean == 0.75)
    #expect(verdict.candidateMean == 1)
    let types = try await h.types()
    #expect(types.filter { $0 == "rehearsal.started" }.count == 2)
    #expect(types.last == "proposal.gated")

    let live = try await h.desk.accept(proposal.id)
    #expect(live.version == 2)
    #expect(live.charter.guardrails == ["better"])
    #expect(try await h.desk.record(proposal.id).status == .accepted)
    #expect(try await h.types().suffix(2) == ["steward.charter.updated", "proposal.accepted"])
}

@Test func secondGateReusesTheBaseline() async throws {
    let h = try Harness()
    try await h.start()
    let a = try await h.desk.propose(h.charter("better"))
    let b = try await h.desk.propose(h.charter("plain"))
    _ = try await h.desk.check(a.id, casebookVersion: h.book.version)
    _ = try await h.desk.check(b.id, casebookVersion: h.book.version)
    let started = try await h.sink.events(from: 1).filter { $0.type == "rehearsal.started" }
    #expect(started.count == 3)
    let proposals = started.map { $0.payload["proposal"]?.stringValue }
    #expect(proposals == [nil, a.id.rawValue, b.id.rawValue])
}

@Test func regressionFailsAndOnlyAPersonCanOverride() async throws {
    let h = try Harness(tolerance: 1)
    try await h.start()
    let proposal = try await h.desk.propose(h.charter("sloppy"))
    let verdict = try await h.desk.check(proposal.id, casebookVersion: h.book.version)
    #expect(!verdict.passed)
    #expect(verdict.regressions.map(\.rawValue) == ["c-1"])
    #expect(verdict.reason == "case regressed")
    await #expect(throws: ProposalError.notAcceptable(proposal.id, .failed)) {
        try await h.desk.accept(proposal.id)
    }

    try await h.desk.override(proposal.id, reason: "c-1 was mislabeled", person: "person:alex")
    let overridden = try await h.sink.events(from: 1).last
    #expect(overridden?.type == "proposal.overridden")
    #expect(overridden?.draft.actor == .person("person:alex"))
    let live = try await h.desk.accept(proposal.id)
    #expect(live.version == 2)
}

@Test func candidateCannotLoosenItsOwnGateOrScorer() async throws {
    let h = try Harness()
    try await h.start()
    var loose = h.charter("sloppy")
    loose.gate = GateConfig(samples: 1, tolerance: 1)
    loose.scorer = .rubric(
        checks: [RubricCheckSpec(kind: "exists", path: "decisions")], passThreshold: 0)
    let proposal = try await h.desk.propose(loose)
    let verdict = try await h.desk.check(proposal.id, casebookVersion: h.book.version)
    #expect(!verdict.passed)
    #expect(verdict.regressions.map(\.rawValue) == ["c-1"])
}

@Test func staleAndClosedProposalsAreRefused() async throws {
    let h = try Harness()
    try await h.start()
    let a = try await h.desk.propose(h.charter("better"))
    let b = try await h.desk.propose(h.charter("better"))
    _ = try await h.desk.check(a.id, casebookVersion: h.book.version)
    _ = try await h.desk.check(b.id, casebookVersion: h.book.version)
    try await h.desk.accept(a.id)
    await #expect(throws: ProposalError.stale(b.id, baseVersion: 1, liveVersion: 2)) {
        try await h.desk.accept(b.id)
    }
    await #expect(throws: ProposalError.closed(a.id, .accepted)) {
        try await h.desk.accept(a.id)
    }
    try await h.desk.reject(b.id, reason: "superseded")
    #expect(try await h.desk.record(b.id).status == .rejected)
    await #expect(throws: ProposalError.closed(b.id, .rejected)) {
        try await h.desk.override(b.id, reason: "x", person: "local")
    }
}

@Test func routineGateRehearsesTheCandidateRoutine() async throws {
    let h = try Harness()
    try await h.start()
    func request(_ version: String) -> RoutineGateRequest {
        RoutineGateRequest(
            steward: h.steward, proposal: ProposalID(unchecked: "prop_r\(version)"),
            name: "label", candidateVersion: version, liveVersion: nil,
            casebookVersion: h.book.version)
    }
    let good = try await h.routineGate.check(request("better"))
    #expect(good.passed)
    #expect(good.candidateMean == 1)
    let bad = try await h.routineGate.check(request("sloppy"))
    #expect(!bad.passed)
    #expect(bad.regressions.map(\.rawValue) == ["c-1"])

    let events = try await h.sink.events(from: 1)
    let started = events.filter { $0.type == "rehearsal.started" }
    #expect(started.count == 3)
    #expect(started[1].payload["routine"] == ["name": "label", "version": "better"])
    let gated = events.filter { $0.type == "proposal.gated" }
    #expect(gated.map { $0.payload["routine"]?["version"] } == ["better", "sloppy"])
}

@Test func baselineIsStaleAfterARoutinePromotion() async throws {
    let h = try Harness()
    try await h.start()
    let a = try await h.desk.propose(h.charter("better"))
    _ = try await h.desk.check(a.id, casebookVersion: h.book.version)
    _ = try await h.sink.append(
        RuntimeEventDraft(
            type: "routine.promoted", steward: h.steward, actor: .system,
            payload: ["name": "label", "version": "v2"]))
    _ = try await h.desk.check(a.id, casebookVersion: h.book.version)
    _ = try await h.desk.check(a.id, casebookVersion: h.book.version)
    let started = try await h.sink.events(from: 1).filter { $0.type == "rehearsal.started" }
    let live = started.filter { $0.payload["proposal"] == nil }
    #expect(live.count == 2)
    #expect(started.count == 5)
}
