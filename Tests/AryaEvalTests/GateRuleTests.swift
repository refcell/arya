import Testing

@testable import AryaEval

private let request = RehearsalRequest(
    steward: "st_triage", charterVersion: 1, casebookVersion: "ab")

/// Builds a result from `case id -> sample pass flags`; a passing sample scores 1, else 0.
private func result(_ cases: [(String, [Bool])], leaks: Set<String> = []) -> RehearsalResult {
    RehearsalResult(
        request: request,
        outcomes: cases.map { id, samples in
            CaseOutcome(
                caseID: id, samples: samples.map { CaseScore(value: $0 ? 1 : 0, passed: $0) },
                leak: leaks.contains(id))
        })
}

struct GateCase: Sendable, CustomTestStringConvertible {
    var name: String
    var baseline: RehearsalResult?
    var candidate: RehearsalResult
    var tolerance: Double
    var passed: Bool
    var reason: String
    var regressions: [String] = []
    var testDescription: String { name }
}

private let gateCases: [GateCase] = [
    GateCase(
        name: "equal scores pass", baseline: result([("a", [true]), ("b", [false])]),
        candidate: result([("a", [true]), ("b", [false])]), tolerance: 0, passed: true,
        reason: "passed"),
    GateCase(
        name: "improvement passes", baseline: result([("a", [true]), ("b", [false])]),
        candidate: result([("a", [true]), ("b", [true])]), tolerance: 0, passed: true,
        reason: "passed"),
    GateCase(
        name: "no baseline fails", baseline: nil, candidate: result([("a", [true])]),
        tolerance: 0, passed: false, reason: "no baseline rehearsal"),
    GateCase(
        name: "different cases fail", baseline: result([("a", [true])]),
        candidate: result([("b", [true])]), tolerance: 0, passed: false,
        reason: "case sets differ"),
    GateCase(
        name: "regressed case fails even when mean rises",
        baseline: result([("a", [true]), ("b", [false]), ("c", [false])]),
        candidate: result([("a", [false]), ("b", [true]), ("c", [true])]), tolerance: 0,
        passed: false, reason: "case regressed", regressions: ["a"]),
    GateCase(
        name: "flaky baseline case is not a regression",
        baseline: result([("a", [true, false])]), candidate: result([("a", [false, false])]),
        tolerance: 0.5, passed: true, reason: "passed"),
    GateCase(
        name: "flaky candidate case is not a regression",
        baseline: result([("a", [true, true])]), candidate: result([("a", [true, false])]),
        tolerance: 0.5, passed: true, reason: "passed"),
    GateCase(
        name: "mean drop beyond tolerance fails",
        baseline: result([("a", [true, true])]), candidate: result([("a", [true, false])]),
        tolerance: 0.25, passed: false, reason: "mean score below baseline"),
    GateCase(
        name: "leak counts as failure", baseline: result([("a", [true])]),
        candidate: result([("a", [true])], leaks: ["a"]), tolerance: 1, passed: false,
        reason: "case regressed", regressions: ["a"]),
]

@Test(arguments: gateCases)
func gateRule(_ c: GateCase) {
    let verdict = GateRule.evaluate(
        baseline: c.baseline, candidate: c.candidate, tolerance: c.tolerance)
    #expect(verdict.passed == c.passed)
    #expect(verdict.reason == c.reason)
    #expect(verdict.regressions == c.regressions)
}

@Test func meanAveragesSamplesThenCases() {
    let r = result([("a", [true, false]), ("b", [true])])
    #expect(GateRule.mean(r) == 0.75)
    #expect(GateRule.mean(result([])) == 0)
}
