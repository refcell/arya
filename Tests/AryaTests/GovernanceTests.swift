import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import Arya

/// The inbox charter with `alex` as a person and replies approvable only by alex.
private func guardedCharterJSON() throws -> Data {
    var charter = try JSONDecoder().decode(Charter.self, from: try inboxCharterJSON())
    charter.bindings.append(.person("person:alex", channel: "inbox"))
    charter.policy.approvers = [
        ApproverRule(action: "reply", people: ["person:alex"], note: "Alex signs off replies")
    ]
    return try CanonicalJSON.encode(charter)
}

@Test func approveRefusesPeopleTheApproverRuleDoesNotList() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try guardedCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let approval = try #require(try await workspace.approvals().first)
    #expect(approval.approvers == ["person:alex"])
    #expect(approval.approverNote == "Alex signs off replies")

    await #expect(
        throws: WorkspaceError.rejected(
            "local may not approve reply actions; only person:alex may (Alex signs off replies)")
    ) {
        try await workspace.approve(approval.id)
    }
    #expect(try await workspace.approvals().map(\.id) == [approval.id])
    #expect(try await opened.types().last == "approval.refused")
    let refused = try #require(try await workspace.ledger().last)
    #expect(refused.actorKind == "human")
    #expect(refused.actorID == "local")
    #expect(await opened.executor.requests.map(\.action.kind) == ["label", "route"])

    let granted = try await workspace.approve(approval.id, as: "person:alex")
    #expect(granted.status == .granted)
    #expect(granted.decidedBy == "person:alex")
    #expect(await opened.executor.requests.map(\.action.kind) == ["label", "route", "reply"])
}

@Test func anyoneMayDenyAGuardedApproval() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try guardedCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let approval = try #require(try await workspace.approvals().first)
    #expect(try await workspace.deny(approval.id).status == .denied)
}

@Test func policySummaryListsToolsActionsAndApprovers() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try guardedCharterJSON())
    let summary = try await workspace.policySummary(steward: "st_inbox")
    #expect(summary.fallback == "ask")
    #expect(summary.bindings.map(\.id) == ["inbox", "person:alex"])
    let inbox = summary.bindings[0]
    #expect(inbox.tools == ["get"])
    #expect(inbox.actions.map(\.kind) == ["label", "route", "reply"])
    #expect(inbox.actions.map(\.decision) == ["auto", "auto", "ask"])
    #expect(inbox.actions[2].approvers == ["person:alex"])
    #expect(inbox.actions[0].approvers == nil)
    #expect(summary.approvers.map(\.people) == [["person:alex"]])
}
