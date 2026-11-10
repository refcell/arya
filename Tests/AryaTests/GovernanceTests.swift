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

@Test func retentionSettingsAreRecordedAndPlanned() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    #expect(try await workspace.retention().defaultDays == nil)
    _ = try await workspace.setRetention(days: 30)
    let summary = try await workspace.setRetention(steward: "st_inbox", days: 90)
    #expect(summary.defaultDays == 30)
    #expect(summary.stewards == [.init(steward: "st_inbox", days: 90)])
    #expect(summary.segments.isEmpty)
    #expect(summary.blocker == nil)
    #expect(summary.archived == 0)
    #expect(try await opened.types().suffix(2) == ["system.retention.set", "system.retention.set"])
    _ = try await workspace.setRetention(steward: "st_inbox", days: nil)
    #expect(try await workspace.retention().stewards.isEmpty)
    await #expect(throws: WorkspaceError.rejected("days must be at least 1")) {
        try await workspace.setRetention(days: 0)
    }
    await #expect(throws: WorkspaceError.notFound("st_missing")) {
        try await workspace.setRetention(steward: "st_missing", days: 3)
    }
}

@Test func enablingEncryptionSealsNewHistoryAndNeedsTheKeyToReopen() async throws {
    let keys = MemoryHomeKeyStore()
    let opened = try await Opened([FakeScript.Run(result: liveResult)], keys: keys)
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let off = try await workspace.encryption()
    #expect(!off.enabled)
    #expect(off.key == nil)
    #expect(off.clearEvents == 1)

    let on = try await workspace.enableEncryption()
    #expect(on.enabled)
    #expect(on.keyAvailable)
    #expect(on.algorithm == "AES-256-GCM")
    #expect(on.since == 2)
    #expect(on.clearEvents == 1)
    let key = try #require(on.key)
    #expect(try keys.key(key) != nil)
    #expect(try await opened.types().last == "system.encryption.enabled")
    #expect(try await workspace.ledger().last?.actorID == "local")

    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    #expect(try await workspace.approvals().count == 1)
    let raw = try String(
        contentsOf: opened.home.url.appendingPathComponent("ledger/000001.jsonl"), encoding: .utf8)
    #expect(!raw.contains("MSG-9"))
    #expect(try await workspace.encryption().clearEvents == 1)

    await #expect(throws: HomeEncryptionError.locked(key: key)) {
        _ = try await Workspace.open(
            home: opened.home.url, ambient: .fixed(stepMillis: 1), keys: MemoryHomeKeyStore())
    }
    let reopened = try await Workspace.open(
        home: opened.home.url, ambient: .fixed(stepMillis: 1), keys: keys)
    #expect(try await reopened.approvals().count == 1)
}

@Test func anAuditExportIsRecordedSignedAndChecks() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let out = opened.home.url.appendingPathComponent("audit")
    let summary = try await workspace.exportAudit(steward: "st_inbox", to: out)
    #expect(summary.verified, "\(summary.issues)")
    #expect(summary.count > 3)
    #expect(summary.key.hasPrefix("key_"))
    #expect(try await opened.types().last == "system.audit.exported")
    #expect(Workspace.verifyAudit(at: out)?.verified == true)
    await #expect(
        throws: WorkspaceError.rejected("the export folder already exists; choose a new one")
    ) {
        _ = try await workspace.exportAudit(steward: "st_inbox", to: out)
    }
}

@Test func applyingRetentionWithNothingEligibleChangesNothing() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.setRetention(days: 1)
    let before = try await opened.types()
    let summary = try await workspace.applyRetention()
    #expect(summary.archived == 0)
    #expect(summary.lastApplied == nil)
    #expect(try await opened.types().filter { $0 != "system.key.added" } == before)
}

@Test func anAuditExportImportsAsTheSameStewardWithItsMemory() async throws {
    let source = try await Opened([FakeScript.Run(result: liveResult)])
    _ = try await source.workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await source.workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    _ = try await source.workspace.remember("Refunds go to billing.", steward: "st_inbox")
    let bundle = source.home.url.appendingPathComponent("audit")
    _ = try await source.workspace.exportAudit(steward: "st_inbox", to: bundle)

    let target = try await Opened()
    let imported = try await target.workspace.importAudit(from: bundle)
    #expect(imported.steward == "st_inbox")
    #expect(imported.notes == 1)
    #expect(
        try await target.workspace.memory(steward: "st_inbox").map(\.text) == [
            "Refunds go to billing."
        ])
    #expect(
        try await target.types().suffix(3) == [
            "steward.created", "memory.added", "system.audit.imported",
        ])
    await #expect(throws: WorkspaceError.self) {
        _ = try await target.workspace.importAudit(from: bundle)
    }

    let events = bundle.appendingPathComponent("events.jsonl")
    var text = String(decoding: try Data(contentsOf: events), as: UTF8.self)
    text = text.replacingOccurrences(of: "billing", with: "shipping")
    try Data(text.utf8).write(to: events)
    let other = try await Opened()
    await #expect(
        throws: WorkspaceError.rejected(
            "the export does not check: events.jsonl does not match the manifest")
    ) {
        _ = try await other.workspace.importAudit(from: bundle)
    }
}

@Test func resealingHistoryLeavesNoEarlierEventsInTheClear() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let enabled = try await workspace.enableEncryption()
    #expect(enabled.clearEvents > 0)
    let resealed = try await workspace.resealHistory()
    #expect(resealed.clearEvents == 0)
    #expect(try await opened.types().last == "system.ledger.resealed")
    #expect(try await workspace.stewards().map(\.id) == ["st_inbox"])
    #expect(try await workspace.verifyLedger().ok)
}
