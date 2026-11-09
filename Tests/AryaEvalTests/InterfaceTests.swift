import AryaCore
import Foundation
import Testing

@testable import AryaEval

@Test func moduleLinks() {
    #expect(AryaEval.name == "AryaEval")
}

@Test func stubReplayerAndRehearserThrow() async {
    await #expect(throws: EvalError.notImplemented("replay")) {
        try await StubReplayer().replay(run: RunID(unchecked: "run_1"))
    }
    let request = RehearsalRequest(
        steward: StewardID(unchecked: "st_triage"), charterVersion: 1, casebookVersion: "ab")
    await #expect(throws: EvalError.notImplemented("rehearsal")) {
        try await StubRehearser().rehearse(request)
    }
}

@Test func stubScorerFailsSafe() {
    #expect(!StubScorer().score(expected: .null, actual: .null).passed)
}

@Test func scorerSpecsBuildScorers() throws {
    let exact = try ScorerSpec.exact(fields: ["choice"]).makeScorer()
    #expect(exact.score(expected: ["choice": "bug"], actual: ["choice": "bug"]).passed)
    let rubric = try ScorerSpec.rubric(
        checks: [RubricCheckSpec(kind: "exists", path: "summary")], passThreshold: 1
    ).makeScorer()
    #expect(rubric.score(expected: [:], actual: ["summary": "ok"]).passed)
    #expect(throws: EvalError.unknownRubricCheck("vibes")) {
        try ScorerSpec.rubric(
            checks: [RubricCheckSpec(kind: "vibes", path: "x")], passThreshold: 1
        ).makeScorer()
    }
}

@Test func samplesAreAtLeastOne() {
    let request = RehearsalRequest(
        steward: StewardID(unchecked: "st_triage"), charterVersion: 1, casebookVersion: "ab",
        samples: 0)
    #expect(request.samples == 1)
}

@Test func evalValueRoundTrips() throws {
    let json = #"{"a":[1,true,null,"x"],"b":{"c":2.5}}"#
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    #expect(value["b"]?["c"] == .double(2.5))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let again = try JSONDecoder().decode(
        JSONValue.self, from: try encoder.encode(value))
    #expect(again == value)
}

@Test func outcomesAreSortedByCase() {
    let request = RehearsalRequest(
        steward: StewardID(unchecked: "st_triage"), charterVersion: 1, casebookVersion: "ab")
    let result = RehearsalResult(
        request: request,
        outcomes: [
            CaseOutcome(caseID: CaseID(rawValue: "case-2")!, samples: []),
            CaseOutcome(caseID: CaseID(rawValue: "case-1")!, samples: []),
        ])
    #expect(result.outcomes.map(\.caseID.rawValue) == ["case-1", "case-2"])
}
