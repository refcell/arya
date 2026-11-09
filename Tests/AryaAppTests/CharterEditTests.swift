import Arya
import Foundation
import Testing

@testable import AryaApp

private let liveCharter: FeatureJSON = [
    "v": 1, "id": "st_triage", "name": "Support inbox triage",
    "outcome": "Every new message is routed within one hour.",
    "metric": ["name": "routed_within_1h", "unit": "ratio", "direction": "up", "target": 0.95],
    "guardrails": ["Never delete a message."],
    "policy": [
        "default": "ask",
        "rules": [
            ["action": "label", "decision": "auto"], ["action": "route", "decision": "auto"],
            ["action": "reply", "decision": "ask", "note": "A sent reply cannot be recalled."],
            ["action": "delete", "decision": "deny"],
        ],
        "risk": [["action": "reply", "level": "medium"]],
    ],
    "bindings": [
        [
            "id": "inbox", "kind": "mcp", "command": "inbox-mcp", "args": [],
            "read": ["search", "get"], "actions": ["label", "route", "reply", "assign"],
        ],
        ["id": "person:sam", "kind": "person", "channel": "inbox"],
    ],
    "triggers": [["kind": "interval", "everySeconds": 900], ["kind": "manual"]],
    "adapter": "fake-triage", "effort": "medium", "limits": ["maxTurns": 10],
]

private let live = LiveCharter(steward: "st_triage", version: 3, charter: liveCharter)

@Test func theEditorReadsTheLiveCharterIntoTheSteps() {
    let draft = NewStewardDraft.editing(live)
    #expect(draft.stewardID == "st_triage")
    #expect(draft.target == "0.95")
    #expect(draft.connections.map(\.id) == ["inbox"])
    #expect(draft.people.map(\.bindingID) == ["person:sam"])
    #expect(draft.never == ["delete"])
    // `assign` has no rule, so it follows the charter's `ask` default.
    #expect(draft.actionKinds.filter(draft.needsSignOff) == ["reply", "assign"])
    #expect(draft.everyMinutes == "15")
    #expect(!draft.wakesOnMessage)
    #expect(draft.adapter == "fake-triage")
}

@Test func anUntouchedEditChangesNothingAndCannotBeProposed() {
    let draft = NewStewardDraft.editing(live)
    #expect(draft.changedFields().isEmpty)
    #expect(draft.problems(.schedule) == ["Nothing changed yet."])
    let proposed = draft.proposedCharter()
    #expect(proposed["limits"] == liveCharter["limits"])
    #expect(proposed["policy"]?["risk"] == liveCharter["policy"]?["risk"])
}

@Test func anEditBecomesAGatedProposalOnTheLiveVersion() throws {
    var draft = NewStewardDraft.editing(live)
    draft.outcome = "Every new message is routed within 30 minutes."
    draft.setSignOff("route", true)
    draft.whyChange = "Routing mistakes reached customers."
    #expect(draft.changedFields() == ["outcome", "sign-off"])
    #expect(draft.problems(.schedule).isEmpty)
    let proposal = try #require(draft.proposal())
    #expect(proposal.baseVersion == 3)
    #expect(proposal.title == "Change outcome and sign-off")
    #expect(proposal.reason == "Routing mistakes reached customers.")
    let rules = proposal.charter["policy"]?["rules"]?.array ?? []
    #expect(rules.contains(["action": "route", "decision": "ask"]))
    #expect(
        rules.contains([
            "action": "reply", "decision": "ask", "note": "A sent reply cannot be recalled.",
        ]))
    #expect(rules.contains(["action": "delete", "decision": "deny"]))
    #expect(proposal.charter["triggers"]?.array?.count == 2)
}

@Test func thePreviewWorkspaceRecordsTheEditAsAProposal() async throws {
    let workspace = PreviewWorkspace.triage(now: FeatureTestClock.now)
    let events = try await workspace.events()
    let current = try #require(LiveCharter.find(events: events, steward: PreviewFixtures.steward))
    var draft = NewStewardDraft.editing(current)
    draft.guardrails += "\nNever share an order number in a reply."
    try await workspace.record(.proposeCharter(try #require(draft.proposal())))
    let after = try await workspace.events()
    #expect(after.last?.type == "proposal.created")
    #expect(after.last?.payload["title"]?.string == "Change guardrails")
}

@Test func theFacadeAcceptsTheEditedCharterAsAProposal() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-charter-edit-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try await Workspace.open(home: home)
    try await workspace.record(.createSteward(NewStewardDraft.example.stewardDraft()))
    let steward = NewStewardDraft.example.stewardID
    let events = try await workspace.ledger(from: 1, limit: nil).map(FacadeFeatureWorkspace.event)
    let current = try #require(LiveCharter.find(events: events, steward: steward))
    var draft = NewStewardDraft.editing(current)
    #expect(draft.changedFields().isEmpty)
    draft.outcome += " Security reports reach the security queue within 15 minutes."
    draft.whyChange = "Security reports waited behind billing questions."
    try await workspace.record(.proposeCharter(try #require(draft.proposal())))
    let proposals = try await workspace.proposals(steward: steward)
    #expect(proposals.count == 1)
    #expect(proposals.first?.baseVersion == current.version)
    #expect(proposals.first?.reason?.hasPrefix("Change outcome") == true)
}
