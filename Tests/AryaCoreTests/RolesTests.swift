import Foundation
import Testing

@testable import AryaCore

private func charter(approvers: [ApproverRule]) throws -> Charter {
    var charter = try Charter.load(from: fixture("charter-triage.json"))
    charter.policy.approvers = approvers
    return charter
}

private func action(_ kind: String, binding: String? = "tracker", name: String? = nil)
    -> ProposedAction
{
    ProposedAction(
        id: "a1", kind: kind, binding: binding, params: name.map { ["name": .string($0)] })
}

@Test func noApproverRuleLeavesApprovalsOpen() throws {
    let policy = try charter(approvers: []).policy
    #expect(policy.authority(of: "local", for: action("label")) == .open)
    #expect(policy.authority(of: "person:alex", for: action("label")).permits)
}

@Test func theMostSpecificApproverRuleDecides() throws {
    let anyone = ApproverRule(action: "*", people: ["local", "person:alex"])
    let viaTracker = ApproverRule(action: "*", binding: "tracker", people: ["local"])
    let close = ApproverRule(action: "close", people: ["person:alex"])
    let closeHere = ApproverRule(action: "close", binding: "tracker", people: ["local"])
    let policy = try charter(approvers: [anyone, viaTracker, close, closeHere]).policy
    #expect(policy.approverRule(forAction: "close", binding: "tracker") == closeHere)
    #expect(policy.approverRule(forAction: "close", binding: "other") == close)
    #expect(policy.approverRule(forAction: "label", binding: "tracker") == viaTracker)
    #expect(policy.approverRule(forAction: "label", binding: "other") == anyone)
    #expect(policy.authority(of: "person:alex", for: action("label")) == .refused(viaTracker))
    #expect(policy.authority(of: "local", for: action("label")) == .allowed(viaTracker))
}

@Test func routineApproverRulesNameTheRoutine() throws {
    let rule = ApproverRule(action: "routine:digest", people: ["person:alex"])
    let policy = try charter(approvers: [rule]).policy
    let digest = action("routine", binding: nil, name: "digest")
    #expect(policy.authority(of: "local", for: digest) == .refused(rule))
    #expect(policy.authority(of: "local", for: action("routine", binding: nil)) == .open)
}

@Test func approverRulesValidateAndRoundTrip() throws {
    let bad = try charter(approvers: [
        ApproverRule(action: "", binding: "nowhere", people: []),
        ApproverRule(action: "close", people: ["person:sam"]),
    ])
    #expect(
        bad.validate().map(\.description) == [
            "policy.approvers[0].action: must not be empty",
            "policy.approvers[0].binding: unknown binding nowhere",
            "policy.approvers[0].people: must not be empty",
            "policy.approvers[1].people: unknown person person:sam",
        ])
    let good = try charter(approvers: [
        ApproverRule(action: "close", people: ["local", "person:alex"], note: "Lead signs off")
    ])
    #expect(good.validate().isEmpty)
    let text = try CanonicalJSON.string(good.policy)
    #expect(text.contains(#""approvers":[{"action":"close","note":"Lead signs off","#))
    #expect(text.contains(#""people":["local","person:alex"]}]"#))
    #expect(try Charter.load(from: CanonicalJSON.encode(good)) == good)
    // An empty list stays off the wire, so existing charters encode byte for byte.
    #expect(!(try CanonicalJSON.string(try charter(approvers: []).policy)).contains("approvers"))
}
