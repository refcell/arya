import Foundation
import Testing

@testable import AryaEval

@Test func moduleLinks() {
    #expect(AryaEval.name == "AryaEval")
}

@Test func stubReplayerAndRehearserThrow() async {
    await #expect(throws: EvalError.notImplemented("replay")) {
        try await StubReplayer().replay(run: "run_1")
    }
    let request = RehearsalRequest(steward: "st_triage", charterVersion: 1, casebookVersion: "ab")
    await #expect(throws: EvalError.notImplemented("rehearsal")) {
        try await StubRehearser().rehearse(request)
    }
}

@Test func stubsFailSafe() async throws {
    let score = StubScorer().score(expected: .null, actual: .null)
    #expect(!score.passed)
    let request = GateRequest(
        steward: "st_triage", proposal: "prop_1", candidateVersion: 2, casebookVersion: "ab")
    let verdict = try await StubGate().check(request)
    #expect(!verdict.passed)
}

@Test func samplesAreAtLeastOne() {
    let request = RehearsalRequest(
        steward: "st_triage", charterVersion: 1, casebookVersion: "ab", samples: 0)
    #expect(request.samples == 1)
}

@Test func evalValueRoundTrips() throws {
    let json = #"{"a":[1,true,null,"x"],"b":{"c":2.5}}"#
    let value = try JSONDecoder().decode(EvalValue.self, from: Data(json.utf8))
    #expect(value["b"]?["c"] == .number(2.5))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let again = try JSONDecoder().decode(
        EvalValue.self, from: try encoder.encode(value))
    #expect(again == value)
}

@Test func outcomesAreSortedByCase() {
    let request = RehearsalRequest(steward: "st_triage", charterVersion: 1, casebookVersion: "ab")
    let result = RehearsalResult(
        request: request,
        outcomes: [
            CaseOutcome(caseID: "case-2", samples: []), CaseOutcome(caseID: "case-1", samples: []),
        ])
    #expect(result.outcomes.map(\.caseID) == ["case-1", "case-2"])
}
