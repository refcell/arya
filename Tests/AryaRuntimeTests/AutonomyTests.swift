import AryaAdapters
import AryaCore
import Testing

@testable import AryaRuntime

@Test func autonomyMapsRiskToDispositions() {
    let table: [(Autonomy, [ActionDisposition])] = [
        (.observe, [.deny, .deny, .deny]),
        (.suggest, [.ask, .ask, .ask]),
        (.actLow, [.auto, .ask, .ask]),
        (.actMedium, [.auto, .auto, .ask]),
    ]
    for (autonomy, expected) in table {
        #expect(Risk.allCases.map { ActionPolicy.allowed(autonomy, risk: $0) } == expected)
    }
}

private func policy(_ autonomy: Autonomy?, rules: [PolicyRule] = [], risk: [RiskRule] = [])
    -> ActionPolicy
{
    var policy = ActionPolicy(
        rules: rules, bindingActions: ["tracker": ["label", "comment", "close"], "mail": ["send"]])
    policy.autonomy = autonomy
    policy.riskRules = risk
    return policy
}

private func act(_ kind: String, _ binding: String? = "tracker", hint: Risk? = nil) -> PolicyAction
{
    PolicyAction(kind: kind, binding: binding, riskHint: hint)
}

@Test func riskComesFromTheMostSpecificRuleAndHintsOnlyRaiseIt() {
    let rules = [
        RiskRule(binding: "mail", level: .high),
        RiskRule(action: "label", level: .low),
        RiskRule(action: "comment", binding: "tracker", level: .high),
        RiskRule(action: "comment", level: .low),
    ]
    let p = policy(.actLow, risk: rules)
    #expect(p.risk(of: act("label")) == .low)
    #expect(p.risk(of: act("comment")) == .high)  // action+binding beats action
    #expect(p.risk(of: act("send", "mail")) == .high)
    #expect(p.risk(of: act("close")) == .medium)  // unlisted
    #expect(p.risk(of: act("label", hint: .high)) == .high)
    #expect(p.risk(of: act("close", hint: .low)) == .medium)  // a hint never lowers
}

@Test func autonomyDecidesWhenNoRuleAndRulesOnlyTighten() {
    let risk = [RiskRule(action: "label", level: .low), RiskRule(action: "close", level: .high)]
    let p = policy(
        .actLow,
        rules: [
            PolicyRule(action: "close", decision: .auto),
            PolicyRule(action: "comment", decision: .deny),
            PolicyRule(action: "label", decision: .ask),
        ], risk: risk)
    // Rule auto on a high-risk action: autonomy tightens it to ask, and says why.
    #expect(
        p.classify(act("close"))
            == PolicyVerdict(
                disposition: .ask, reason: "autonomy:act_low:high", risk: .high, autonomy: .actLow))
    // Rule ask on a low-risk action stays ask (a rule may tighten autonomy).
    #expect(p.classify(act("label")).reason == "rule:label")
    #expect(p.classify(act("label")).disposition == .ask)
    #expect(p.classify(act("comment")).disposition == .deny)
    // Structural refusals stay deny.
    #expect(p.classify(act("label", "nowhere")).reason == "unknown_binding:nowhere")

    let open = policy(.actLow, risk: risk)
    #expect(open.classify(act("label")).disposition == .auto)
    #expect(open.classify(act("label")).reason == "autonomy:act_low:low")
    #expect(policy(.observe).classify(act("label")).disposition == .deny)
    // Without autonomy the old behavior holds: default ask, no risk recorded.
    #expect(
        policy(nil).classify(act("label")) == PolicyVerdict(disposition: .ask, reason: "default"))
}

@Test func unlistedRoutinesAskEvenAtHighAutonomy() {
    var p = policy(.actMedium, risk: [RiskRule(action: "routine:digest", level: .low)])
    p.rules = []
    let routine = PolicyAction(
        kind: "routine", binding: nil, routineName: "digest", routineVersion: "v1")
    #expect(p.classify(routine).disposition == .ask)
    p.rules = [PolicyRule(action: "routine:digest@v1", decision: .auto)]
    #expect(p.classify(routine).disposition == .auto)
}

@Test func charterEncodingIsUnchangedWithoutAutonomyOrRisk() throws {
    let json = try CanonicalJSON.jsonValue(triageCharter())
    #expect(json["autonomy"] == nil)
    #expect(json["policy"]?["risk"] == nil)
    var charter = triageCharter()
    charter.autonomy = .actLow
    charter.policy.risk = [RiskRule(action: "label", level: .low)]
    let round = try CanonicalJSON.decode(
        Charter.self, from: CanonicalJSON.encode(charter))
    #expect(round == charter)
    #expect(try CanonicalJSON.jsonValue(charter)["autonomy"] == "act_low")
}

@Test func runsRecordRiskAndAutonomyOnProposals() async throws {
    var charter = triageCharter()
    charter.autonomy = .actLow
    charter.policy = Policy(risk: [RiskRule(action: "label", level: .low)])
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    let outcome = try await harness.start(charter: charter)
    let byID = Dictionary(uniqueKeysWithValues: outcome.disposals.map { ($0.action.id, $0) })
    #expect(byID["a1"]?.verdict.disposition == .auto)  // label: low
    #expect(byID["a2"]?.verdict.disposition == .ask)  // comment: medium by default
    let proposed = try await harness.sink.events(from: 1).filter {
        $0.type == ActionEventType.proposed
    }
    #expect(proposed.map { $0.payload["risk"] } == ["low", "medium"])
    #expect(proposed.allSatisfy { $0.payload["autonomy"] == "act_low" })
    #expect(proposed[1].payload["reason"] == "autonomy:act_low:medium")
}

@Test func runsCarryTheAdaptersWhyAndRiskHint() async throws {
    let result: JSONValue = [
        "summary": "Labeled ISSUE-7.",
        "decisions": [["id": "d1", "choice": "bug", "why": "it crashes on save"]],
        "actions": [
            [
                "id": "a1", "kind": "label", "binding": "tracker", "target": "tracker:ISSUE-7",
                "params": ["label": "bug"], "risk": "high", "why": "so the owner sees it",
            ]
        ],
    ]
    let harness = RunHarness(FakeScript.Run(result: result))
    _ = try await harness.start()
    let decision = try #require(try await harness.last(RunEventType.decision))
    #expect(decision.payload["decision"]?["why"] == "it crashes on save")
    let proposed = try #require(try await harness.last(ActionEventType.proposed))
    #expect(proposed.payload["action"]?["why"] == "so the owner sees it")
    #expect(proposed.payload["action"]?["risk"] == "high")
}
