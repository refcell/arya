import Foundation
import Testing

@testable import AryaCore

private func triage() throws -> Charter {
    try Charter.load(from: fixture("charter-triage.json"))
}

@Test func charterFixtureLoads() throws {
    let charter = try triage()
    #expect(charter.id.rawValue == "st_triage")
    #expect(charter.metric.target == 0.95)
    #expect(charter.bindings.map(\.kind) == [.mcp, .person])
    #expect(charter.binding("tracker")?.read == ["search", "get"])
    #expect(charter.triggers == [.interval(everySeconds: 900), .manual])
    #expect(charter.crew.maxParallel == 3)
    #expect(
        charter.scorer == .exact(fields: ["decisions.choice", "actions.kind", "actions.target"]))
    #expect(charter.validate().isEmpty)
}

@Test func charterCanonicalGolden() throws {
    let text = try CanonicalJSON.string(try triage())
    #expect(text == (try fixtureText("charter-triage.canonical.json")))
    // Round trip through the canonical form gives the same value.
    #expect(try Charter.load(from: Data(text.utf8)) == (try triage()))
}

@Test func charterDefaults() throws {
    let minimal = #"""
        {"v":1,"id":"st_min","name":"Min","outcome":"Something good happens.",
         "metric":{"name":"m","unit":"count","direction":"down"},"adapter":"fake",
         "scorer":{"kind":"exact","fields":["decisions.choice"]}}
        """#
    let charter = try Charter.load(from: Data(minimal.utf8))
    #expect(charter.policy.default == .ask)
    #expect(charter.triggers == [.manual])
    #expect(charter.effort == .medium)
    #expect(charter.gate == GateConfig(samples: 1, tolerance: 0))
    #expect(charter.limits == Limits())
}

@Test func policyDecisions() throws {
    var policy = try triage().policy
    #expect(policy.decision(forAction: "label") == .auto)
    #expect(policy.decision(forAction: "close") == .deny)
    #expect(policy.decision(forAction: "assign") == .ask)
    #expect(policy.decision(forAction: "unheard-of") == .ask)
    policy.rules.append(.init(action: "label", binding: "tracker", decision: .deny))
    #expect(policy.decision(forAction: "label", binding: "tracker") == .deny)
    #expect(policy.decision(forAction: "label", binding: "other") == .auto)
}

@Test func charterValidationReportsEveryIssue() throws {
    var charter = try triage()
    charter.outcome = "  "
    charter.bindings.append(.person("tracker", channel: "inbox"))
    charter.bindings.append(.mcp("files", command: ""))
    charter.triggers.append(.message(from: "person:sam"))
    charter.policy.rules.append(.init(action: "label", binding: "nowhere", decision: .auto))
    charter.gate.samples = 0
    charter.scorer = .exact(fields: [])
    let paths = charter.validate().map(\.path)
    #expect(
        paths == [
            "outcome", "bindings[2].id", "bindings[3].command", "triggers[2].from",
            "policy.rules[2].binding", "scorer.fields", "gate.samples",
        ])
    #expect(throws: CharterError.self) {
        try Charter.load(from: CanonicalJSON.encode(charter))
    }
}

@Test func malformedCharterIsReported() {
    #expect {
        try Charter.load(from: Data(#"{"v":1}"#.utf8))
    } throws: { error in
        if case CharterError.malformed = error { return true }
        return false
    }
    #expect(throws: CharterError.self) {
        try Charter.load(from: Data(#"{"v":1,"id":"triage"}"#.utf8))
    }
}

@Test func rubricScorerCodes() throws {
    let spec = ScorerSpec.rubric(
        checks: [RubricCheckSpec(kind: "equals", path: "decisions.choice", value: "bug")],
        passThreshold: 0.5)
    let text = try CanonicalJSON.string(spec)
    #expect(
        text == #"{"checks":[{"kind":"equals","path":"decisions.choice","value":"bug","#
            + #""weight":1}],"kind":"rubric","passThreshold":0.5}"#)
    #expect(try JSONDecoder().decode(ScorerSpec.self, from: Data(text.utf8)) == spec)
}

@Test func caseFixtureLoads() throws {
    let value = try Case.load(from: fixture("case-0007.json"))
    #expect(value.id.rawValue == "case-0007")
    #expect(value.context.toolResults.first?.tool == "tracker.get")
    #expect(value.expected["decisions"]?[0]?["choice"] == "bug")
    let text = try CanonicalJSON.string(value)
    #expect(text == (try fixtureText("case-0007.canonical.json")))
    #expect(try Case.load(from: Data(text.utf8)) == value)
}

@Test func caseValidation() {
    let bad = Case(id: CaseID(rawValue: "c1")!, input: CaseInput(text: " "), expected: [1])
    #expect(bad.validate().map(\.path) == ["input.text", "expected"])
}

@Test func refusingGateRefuses() async throws {
    let request = GateCheckRequest(
        steward: StewardID(rawValue: "st_a")!, proposal: ProposalID(rawValue: "prop_1")!,
        candidateVersion: 2, casebookVersion: "abc")
    let verdict = try await RefusingGate().check(request)
    #expect(!verdict.passed)
}
