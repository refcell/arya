import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private func charterJSON(id: String, name: String, every: Int? = nil) throws -> Data {
    var charter = try Charter.load(from: try inboxCharterJSON(id: id))
    charter.name = name
    if let every { charter.triggers = [.interval(everySeconds: every), .manual] }
    return try CanonicalJSON.encode(charter)
}

@Test func fleetPutsStewardsThatNeedYouFirst() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try charterJSON(id: "st_a", name: "Alpha"))
    _ = try await workspace.createSteward(
        charter: try charterJSON(id: "st_b", name: "Bravo", every: 900))
    _ = try await workspace.createSteward(charter: try charterJSON(id: "st_z", name: "Zulu"))
    _ = try await workspace.startRun(steward: "st_z", input: "New message MSG-9")
    _ = try await workspace.markReady(steward: "st_b")
    try await workspace.pauseSteward("st_a")

    let fleet = try await workspace.fleet()

    #expect(fleet.map(\.steward) == ["st_z", "st_b", "st_a"])
    let zulu = fleet[0]
    #expect(zulu.pendingApprovals == 1)
    #expect(zulu.needsYou == 1)
    #expect(zulu.lastRun?.title == "Billing question; labeled, routed, reply drafted.")
    #expect(zulu.lastRun?.status == "finished")
    #expect(zulu.nextWake == nil)
    #expect(zulu.metric == "routed_within_1h")
    let bravo = fleet[1]
    #expect(bravo.ready && bravo.state == "active")
    #expect(bravo.nextWake != nil)
    #expect(bravo.lastRun == nil)
    #expect(fleet[2].state == "paused")
    #expect(fleet[2].nextWake == nil)
}

@Test func charterEditsGoThroughTheGatedProposalPath() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    var original = try Charter.load(from: try inboxCharterJSON())
    original.limits.maxTurns = 7
    original.autonomy = .actLow
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(original))

    let loaded = try await workspace.charterDraft(steward: "st_inbox")
    #expect(loaded.version == 1)
    #expect(loaded.draft.level == "act_low")
    #expect(try loaded.draft.applied(to: original) == original)
    await #expect(throws: WorkspaceError.rejected("the draft changes nothing")) {
        try await workspace.proposeCharter(steward: "st_inbox", draft: loaded.draft)
    }

    var edit = loaded.draft
    edit.outcome = "Every new message is routed within thirty minutes."
    edit.level = "suggest"
    let proposal = try await workspace.proposeCharter(
        steward: "st_inbox", draft: edit, baseVersion: loaded.version, title: "Faster")

    #expect(proposal.status == "open")
    #expect(proposal.baseVersion == 1 && proposal.candidateVersion == 2)
    let live = try Charter.load(from: try await workspace.charter("st_inbox"))
    #expect(live == original)
    let candidate = try #require(
        try ProposalSummaryCharter.charter(workspace, proposal: proposal.id))
    #expect(candidate.outcome == edit.outcome)
    #expect(candidate.autonomy == .suggest)
    #expect(candidate.limits.maxTurns == 7)
    await #expect(throws: WorkspaceError.self) {
        try await workspace.proposeCharter(steward: "st_inbox", draft: edit, baseVersion: 0)
    }
    var bad = edit
    bad.level = "sometimes"
    await #expect(throws: WorkspaceError.self) {
        try await workspace.proposeCharter(steward: "st_inbox", draft: bad)
    }
}

/// Reads a proposal's candidate charter from the ledger.
private enum ProposalSummaryCharter {
    static func charter(_ workspace: Workspace, proposal: String) throws -> Charter? {
        let events = try workspace.reader.events()
        for event in events where event.type.rawValue == "proposal.created" {
            guard case .object(let body) = event.payload,
                body["proposal"] == .string(proposal) || body["id"] == .string(proposal),
                let charter = body["charter"]
            else { continue }
            return try CanonicalJSON.decode(Charter.self, from: try CanonicalJSON.encode(charter))
        }
        return nil
    }
}

@Test func serveStatusShowsWhoServesTheLastTickAndNextWakes() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(
        charter: try charterJSON(id: "st_b", name: "Bravo", every: 900))
    _ = try await workspace.createSteward(charter: try charterJSON(id: "st_a", name: "Alpha"))
    _ = try await workspace.markReady(steward: "st_b")
    let other = try await Workspace.open(home: opened.home.url)

    let idle = try await other.serveStatus()
    #expect(!idle.serving && !idle.servingHere && idle.lastTick == nil)
    #expect(idle.stewards.map(\.steward) == ["st_a", "st_b"])
    #expect(idle.stewards.map(\.state) == ["off", "due"])
    #expect(idle.stewards[1].intervalSeconds == 900)
    #expect(idle.stewards[1].nextWake != nil)

    #expect(try await workspace.startServing(every: .milliseconds(10)))
    for _ in 0..<200 where try await other.serveStatus().lastTick == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let busy = try await other.serveStatus()
    #expect(busy.serving && !busy.servingHere)
    #expect(busy.lastTick != nil)
    #expect(try await workspace.serveStatus().servingHere)

    await workspace.stopServing()
    #expect(!(try await other.serveStatus().serving))
}

@Test func messagesAskCorrectAndHandOffThroughTheInbox() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())

    let asked = try await workspace.message(steward: "st_inbox", text: "Is MSG-9 handled?")
    let run = try #require(asked.run)
    #expect(asked.note == nil)
    #expect(run.trigger == "message")
    #expect(try await workspace.run(run.id)?.input == "local asks: Is MSG-9 handled?")

    let corrected = try await workspace.message(
        steward: "st_inbox", text: "Card updates are billing.", intent: "correct")
    #expect(corrected.run == nil)
    let note = try #require(corrected.note)
    #expect(try await workspace.memory(steward: "st_inbox").map(\.id) == [note])

    let handed = try await workspace.message(
        steward: "st_inbox", text: "Sort the backlog", intent: "handoff")
    let handoff = try #require(handed.run)
    #expect(
        try await workspace.run(handoff.id)?.input == "local hands this to you: Sort the backlog")

    let thread = try await workspace.conversation(steward: "st_inbox")
    #expect(thread.map(\.intent) == ["ask", "correct", "handoff"])
    #expect(thread.allSatisfy { $0.person == "local" && $0.channel == "app" })
    #expect(try await workspace.conversation(steward: "st_inbox", person: "local") == thread)
    #expect(try await workspace.conversation(steward: "st_inbox", person: "person:sam").isEmpty)
    #expect(try await workspace.ledger().contains { $0.id == asked.event })

    let manual = try await workspace.runNow(steward: "st_inbox", note: "Check the queue")
    #expect(manual.trigger == "manual")
    await #expect(throws: WorkspaceError.self) {
        try await workspace.message(steward: "st_inbox", text: "hi", by: "person:nobody")
    }
    await #expect(throws: WorkspaceError.self) {
        try await workspace.message(steward: "st_inbox", text: "hi", intent: "shout")
    }
    await #expect(throws: WorkspaceError.self) {
        try await workspace.message(steward: "st_inbox", text: "  ")
    }
}
