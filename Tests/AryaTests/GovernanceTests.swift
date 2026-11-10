import AryaAdapters
import AryaCore
import AryaLedger
import AryaRuntime
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

@Test func abortStopsARunningRunAndExecutesNothing() async throws {
    let opened = try await Opened([FakeScript.Run(steps: [.hang], result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let running = Task { try await workspace.startRun(steward: "st_inbox", input: "MSG-9") }
    var started: String?
    for _ in 0..<5000 where started == nil {
        started = try await workspace.runs().first?.id
        if started == nil { try await Task.sleep(for: .milliseconds(1)) }
    }
    let run = try #require(started)

    _ = try await workspace.abortRun(run, reason: "Wrong customer")
    let ended = try await running.value

    #expect(ended.status == .finished)
    #expect(ended.endStatus == "stopped")
    #expect(await opened.executor.requests.isEmpty)
    #expect(try await workspace.approvals().isEmpty)
    let types = try await opened.types()
    #expect(types.contains("run.abort.requested"))
    #expect(!types.contains("action.proposed"))
    #expect(types.last == "run.finished")
    let asked = try #require(
        try await workspace.ledger().first { $0.type == "run.abort.requested" })
    #expect(asked.actorID == "local")
    #expect(asked.payload == #"{"reason":"Wrong customer"}"#)
    await #expect(throws: WorkspaceError.rejected("\(run) is already finished")) {
        try await workspace.abortRun(run)
    }
}

@Test func abortFailsARunNoProcessHolds() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    let charter = try JSONDecoder().decode(Charter.self, from: try inboxCharterJSON())
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let started = RunStarted(
        input: RunInputRecord(kind: .manual, text: "MSG-9"), charterVersion: 1,
        adapter: charter.adapter, effort: charter.effort, instructions: "", limits: charter.limits)
    _ = try await workspace.sink.append(
        RuntimeEventDraft(
            type: RunEventType.started, steward: charter.id, run: RunID(unchecked: "run_orphan"),
            actor: .localUser, payload: try Workspace.json(started)))

    let aborted = try await workspace.abortRun("run_orphan", as: "person:alex")

    #expect(aborted.status == .failed)
    #expect(try await opened.types().suffix(2) == ["run.abort.requested", "run.failed"])
    await #expect(throws: WorkspaceError.notFound("run_missing")) {
        try await workspace.abortRun("run_missing")
    }
}

/// The inbox charter where a label is undone by `unlabel`, which waits for approval.
private func undoableCharterJSON(allowUnlabel: Bool = true) throws -> Data {
    var charter = try JSONDecoder().decode(Charter.self, from: try inboxCharterJSON())
    if allowUnlabel { charter.bindings[0].actions.append("unlabel") }
    charter.policy.undo = [UndoRule(action: "label", with: "unlabel", note: "Restores the label")]
    return try CanonicalJSON.encode(charter)
}

@Test func undoProposesTheCompensationThroughPolicy() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try undoableCharterJSON())
    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let options = try await workspace.undoOptions(run: run.id)
    #expect(options.map(\.action) == ["a1"])
    #expect(options.first?.with == "unlabel")
    #expect(options.first?.undoneBy == nil)

    let undo = try await workspace.undoAction(run: run.id, action: "a1", reason: "Wrong label")

    #expect(undo.decision == "ask")
    #expect(!undo.executed)
    #expect(undo.option.undoneBy == "undo:a1")
    let approval = try #require(undo.approval)
    let types = try await opened.types()
    #expect(types.suffix(3) == ["action.undo.requested", "action.proposed", "approval.requested"])
    _ = try await workspace.approve(approval)
    let request = try #require(await opened.executor.requests.last)
    #expect(request.action.kind == "unlabel")
    #expect(request.action.target == "inbox:MSG-9")
    #expect(request.action.params?["undoes"] == "a1")
    #expect(request.action.params?["previous"] == .null)
    #expect(try await workspace.undoOptions(run: run.id).first?.undoneBy == "undo:a1")
    await #expect(throws: WorkspaceError.rejected("a1 in \(run.id) is already undone by undo:a1")) {
        try await workspace.undoAction(run: run.id, action: "a1")
    }
    await #expect(throws: WorkspaceError.self) {
        try await workspace.undoAction(run: run.id, action: "a2")
    }
}

@Test func undoIsRefusedWhenTheBindingCannotCarryTheCompensation() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try undoableCharterJSON(allowUnlabel: false))
    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let undo = try await workspace.undoAction(run: run.id, action: "a1")
    #expect(undo.decision == "deny")
    #expect(try await opened.types().suffix(2) == ["action.proposed", "action.rejected"])
}
