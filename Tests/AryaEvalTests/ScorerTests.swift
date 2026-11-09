import AryaCore
import Testing

@testable import AryaEval

private let expected: JSONValue = .object([
    "decisions": .array([.object(["choice": .string("bug")])]),
    "actions": .array([
        .object(["kind": .string("label"), "target": .string("tracker:ISSUE-7")])
    ]),
])

private func actual(choice: String, target: String) -> JSONValue {
    .object([
        "decisions": .array([.object(["choice": .string(choice)])]),
        "actions": .array([.object(["kind": .string("label"), "target": .string(target)])]),
        "summary": .string("Labeled the login timeout as a bug."),
    ])
}

@Test func valuesFanOutThroughArrays() {
    #expect(expected.values(at: "actions.kind") == [.string("label")])
    #expect(expected.values(at: "missing.field").isEmpty)
}

@Test func exactScorerMatchesChosenFields() {
    let scorer = ExactScorer(fields: ["decisions.choice", "actions.kind", "actions.target"])
    let full = scorer.score(
        expected: expected, actual: actual(choice: "bug", target: "tracker:ISSUE-7"))
    #expect(full.value == 1 && full.passed && full.notes.isEmpty)
    #expect(full.text == "passed (1)")
    let partial = scorer.score(
        expected: expected, actual: actual(choice: "feature", target: "tracker:ISSUE-7"))
    #expect(!partial.passed)
    #expect(abs(partial.value - 2.0 / 3.0) < 1e-9)
    #expect(partial.notes == ["decisions.choice differs"])
    #expect(!ExactScorer(fields: []).score(expected: expected, actual: expected).passed)
}

@Test(arguments: [
    (RubricCheck(kind: .matchesExpected, path: "decisions.choice"), true),
    (RubricCheck(kind: .exists, path: "summary"), true),
    (RubricCheck(kind: .absent, path: "actions.kind"), false),
    (RubricCheck(kind: .equals, path: "actions.kind", value: .string("label")), true),
    (RubricCheck(kind: .equals, path: "actions.kind", value: .string("close")), false),
    (RubricCheck(kind: .contains, path: "summary", value: .string("timeout")), true),
    (RubricCheck(kind: .contains, path: "summary", value: .int(1)), false),
])
func rubricChecks(check: RubricCheck, holds: Bool) {
    let result = actual(choice: "bug", target: "tracker:ISSUE-7")
    #expect(check.holds(expected: expected, actual: result) == holds)
}

@Test func rubricScorerWeighsChecks() {
    let scorer = RubricScorer(
        checks: [
            RubricCheck(kind: .matchesExpected, path: "decisions.choice", weight: 3),
            RubricCheck(kind: .absent, path: "actions", weight: 1),
        ], passThreshold: 0.75)
    let score = scorer.score(expected: expected, actual: actual(choice: "bug", target: "x"))
    #expect(score.value == 0.75)
    #expect(score.passed)
    #expect(score.notes == ["absent actions failed"])
    #expect(!RubricScorer(checks: []).score(expected: expected, actual: expected).passed)
}

@Test func scoresCarryChecksAndOneLineText() {
    let exact = ExactScorer(fields: ["decisions.choice", "actions.kind"]).score(
        expected: expected, actual: actual(choice: "feature", target: "tracker:ISSUE-7"))
    #expect(
        exact.checks == [
            CheckResult(
                label: "decisions.choice matches expected", passed: false,
                text: "expected bug, got feature", phrase: "choice: feature, not bug"),
            CheckResult(
                label: "actions.kind matches expected", passed: true, text: "label",
                phrase: "kind: label"),
        ])
    #expect(
        exact.text
            == "failed (0.5): decisions.choice matches expected: expected bug, got feature")

    let rubric = RubricScorer(
        checks: [
            RubricCheck(kind: .equals, path: "decisions.choice", value: "bug", weight: 3),
            RubricCheck(kind: .exists, path: "actions.kind", value: nil, weight: 1),
        ],
        passThreshold: 0.75
    ).score(expected: expected, actual: actual(choice: "feature", target: "tracker:ISSUE-7"))
    #expect(rubric.checks?.map(\.label) == ["decisions.choice is bug", "actions.kind is present"])
    #expect(rubric.checks?.map(\.weight) == [3, 1])
    #expect(rubric.text == "failed (0.25): decisions.choice is bug: found feature")
    #expect(CaseScore(value: 0, passed: false, notes: ["leak"]).text == "failed (0): leak")
}
