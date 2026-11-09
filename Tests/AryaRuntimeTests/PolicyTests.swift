import Testing

@testable import AryaRuntime

private let triagePolicy = ActionPolicy(
    rules: [
        PolicyRule(action: "label", decision: .auto),
        PolicyRule(action: "close", decision: .deny),
        PolicyRule(action: "label", decision: .deny),
    ],
    bindingActions: [
        "tracker": ["label", "comment", "assign", "close"],
        "person:alex": ["message"],
    ]
)

struct PolicyCase: Sendable, CustomTestStringConvertible {
    let kind: String
    let binding: String?
    let disposition: ActionDisposition
    let reason: String
    var testDescription: String { "\(binding ?? "-").\(kind) -> \(disposition)" }
}

private let cases: [PolicyCase] = [
    PolicyCase(kind: "label", binding: "tracker", disposition: .auto, reason: "rule:label"),
    PolicyCase(kind: "close", binding: "tracker", disposition: .deny, reason: "rule:close"),
    PolicyCase(kind: "comment", binding: "tracker", disposition: .ask, reason: "default"),
    PolicyCase(kind: "message", binding: "person:alex", disposition: .ask, reason: "default"),
    PolicyCase(
        kind: "delete", binding: "tracker", disposition: .deny, reason: "not_allowed:tracker.delete"
    ),
    PolicyCase(
        kind: "label", binding: "mail", disposition: .deny, reason: "unknown_binding:mail"),
    PolicyCase(kind: "label", binding: nil, disposition: .deny, reason: "no_binding"),
    PolicyCase(kind: "label", binding: "", disposition: .deny, reason: "no_binding"),
    PolicyCase(kind: "", binding: "tracker", disposition: .deny, reason: "empty_kind"),
    PolicyCase(kind: "routine", binding: nil, disposition: .ask, reason: "default"),
]

@Test(arguments: cases)
func classifiesActions(_ testCase: PolicyCase) {
    let verdict = triagePolicy.classify(
        PolicyAction(kind: testCase.kind, binding: testCase.binding))
    #expect(verdict.disposition == testCase.disposition)
    #expect(verdict.reason == testCase.reason)
}

@Test func defaultIsAsk() {
    #expect(ActionPolicy().defaultDisposition == .ask)
    let policy = ActionPolicy(bindingActions: ["tracker": ["anything"]])
    #expect(policy.classify(PolicyAction(kind: "anything", binding: "tracker")).disposition == .ask)
}

@Test func explicitDefaultApplies() {
    let policy = ActionPolicy(
        defaultDisposition: .auto, rules: [PolicyRule(action: "routine", decision: .ask)],
        bindingActions: ["tracker": ["comment"]])
    #expect(policy.classify(PolicyAction(kind: "comment", binding: "tracker")).disposition == .auto)
    #expect(policy.classify(PolicyAction(kind: "routine", binding: nil)).disposition == .ask)
}

@Test func bindingQualifiedRulesMatchOnlyThatBinding() {
    let policy = ActionPolicy(
        rules: [
            PolicyRule(action: "message", binding: "person:alex", decision: .auto),
            PolicyRule(action: "message", decision: .deny),
        ],
        bindingActions: ["person:alex": ["message"], "person:sam": ["message"]])
    let alex = policy.classify(PolicyAction(kind: "message", binding: "person:alex"))
    #expect(alex == PolicyVerdict(disposition: .auto, reason: "rule:person:alex.message"))
    let sam = policy.classify(PolicyAction(kind: "message", binding: "person:sam"))
    #expect(sam == PolicyVerdict(disposition: .deny, reason: "rule:message"))
}

@Test func structuralRefusalBeatsAutoRule() {
    let policy = ActionPolicy(
        defaultDisposition: .auto, rules: [PolicyRule(action: "close", decision: .auto)],
        bindingActions: ["tracker": ["label"]])
    let verdict = policy.classify(PolicyAction(kind: "close", binding: "tracker"))
    #expect(verdict.disposition == .deny)
}
