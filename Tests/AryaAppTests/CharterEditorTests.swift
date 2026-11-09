import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let charter = PreviewFixtures.charter

@Test func unchangedDraftRoundTripsTheCharter() {
    let draft = CharterDraft(charter: charter)
    #expect(draft.issues.isEmpty)
    #expect(draft.changedFields(from: charter).isEmpty)
    #expect(draft.charter["adapter"] == "exec-default")
    #expect(draft.charter["metric"] == charter["metric"])
    #expect(draft.charter["bindings"] == charter["bindings"])
    #expect(draft.charter["triggers"] == charter["triggers"])
    #expect(draft.charter["policy"] == charter["policy"])
    #expect(draft.metricTarget == "0.95")
    #expect(draft.bindings[0].actions == "label, comment, assign")
}

@Test func editsShowAsChangedFieldsAndTitle() {
    var draft = CharterDraft(charter: charter)
    draft.outcome = "Every new issue is labeled within thirty minutes."
    draft.guardrails.append("Never reopen an issue.")
    draft.effort = "high"
    #expect(draft.changedFields(from: charter) == ["outcome", "guardrails", "effort"])
    #expect(
        CharterText.title(draft.changedFields(from: charter))
            == "Change outcome, guardrails and effort")
    #expect(CharterText.title(["policy"]) == "Change policy")
    #expect(CharterText.title([]) == "No changes")
    #expect(draft.charter["guardrails"]?.strings.last == "Never reopen an issue.")
}

@Test func validationNamesEachProblem() {
    var draft = CharterDraft(charter: charter)
    draft.outcome = "  "
    draft.metricTarget = "high"
    draft.bindings[1].id = "tracker"
    draft.addBinding()
    draft.addRule()
    draft.triggers = []
    #expect(
        draft.issues == [
            "Add at least one trigger, such as manual.", "Binding id tracker is used twice.",
            "Every binding needs an id.", "Every policy rule needs an action.",
            "The metric target must be a number.", "The outcome is empty.",
        ])
    draft.triggers = [TriggerDraft(key: draft.makeKey(), kind: "interval", everySeconds: 0)]
    #expect(draft.issues.contains("Interval triggers need at least one second between runs."))
    draft.bindings[1].channel = ""
    draft.bindings[0].command = ""
    draft.policyRules[0] = PolicyRuleDraft(
        key: 99, action: "label", decision: "auto", binding: "chat")
    #expect(draft.issues.contains("Person binding tracker needs a channel."))
    #expect(draft.issues.contains("Binding tracker needs a server command."))
    #expect(draft.issues.contains("Policy rule label names unknown binding chat."))
}

@Test func personBindingsDropServerFieldsAndBlankGuardrailsVanish() {
    var draft = CharterDraft(charter: charter)
    draft.bindings[0].kind = "person"
    draft.bindings[0].channel = "inbox"
    draft.guardrails.append("   ")
    let tracker = draft.charter["bindings"]?.array?.first
    #expect(tracker?["channel"] == "inbox")
    #expect(tracker?["read"] == nil)
    #expect(tracker?["args"] == nil)
    #expect(draft.charter["guardrails"]?.strings.count == 2)
}

@Test func ruleBindingsAndMessageSendersSurviveEdits() {
    guard case .object(var members) = charter else { return }
    members["policy"] = [
        "default": "ask", "rules": [["action": "label", "binding": "tracker", "decision": "auto"]],
    ]
    members["triggers"] = [["kind": "message", "from": "person:alex"]]
    let json = FeatureJSON.object(members)
    var draft = CharterDraft(charter: json)
    #expect(draft.charter["policy"] == json["policy"])
    #expect(draft.charter["triggers"] == json["triggers"])
    draft.triggers[0].kind = "manual"
    #expect(draft.charter["triggers"] == [["kind": "manual"]])
}

@Test func liveCharterIsTheLatestVersion() throws {
    var log = FeatureEventBuilder(start: now)
    log.add("steward.created", ["charter": ["outcome": "a"], "version": 1])
    log.add("steward.charter.updated", ["charter": ["outcome": "b"], "version": 2])
    let live = try #require(LiveCharter.find(events: log.events, steward: PreviewFixtures.steward))
    #expect(live.version == 2)
    #expect(live.charter["outcome"] == "b")
    #expect(LiveCharter.find(events: log.events, steward: "st_none") == nil)
}

@Test func proposingRecordsACandidateNeverAnEdit() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    var draft = CharterDraft(charter: charter)
    draft.effort = "low"
    let proposal = CharterProposal(
        steward: PreviewFixtures.steward, baseVersion: 1, charter: draft.charter,
        title: "Change effort", reason: "Runs are simple.")
    let written = try await workspace.record(.proposeCharter(proposal))
    #expect(written.map(\.type) == ["proposal.created"])
    #expect(written[0].actor == .localUser)
    #expect(written[0].payload["candidateVersion"] == 2)
    let events = await workspace.events()
    #expect(!events.contains { $0.type == "steward.charter.updated" })
    #expect(
        LiveCharter.find(events: events, steward: PreviewFixtures.steward)?.charter["effort"]
            == "medium")
    let item = try #require(ChangeList.build(events: events).open.first)
    #expect(item.title == "Change effort")
    #expect(ChangesText.meta(item) == "charter v2 · from local")
    var stale = proposal
    stale.baseVersion = 0
    await #expect(throws: FeatureWriteError.staleCharter(live: 1)) {
        try await workspace.record(.proposeCharter(stale))
    }
}
