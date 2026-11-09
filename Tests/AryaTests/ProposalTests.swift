import AryaCore
import AryaLedger
import AryaMemory
import AryaRuntime
import Foundation
import Testing

@testable import Arya

/// A steward with the small casebook imported; the script answers MSG-3 wrong.
private func gatedHome() async throws -> Opened {
    let opened = try await Opened(improvementScript())
    var charter = inboxCharter()
    charter.scorer = .exact(fields: ["decisions.choice"])
    _ = try await opened.workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    _ = try await opened.workspace.importCasebook(
        steward: "st_inbox", data: try casebookLines(), name: "inbox")
    return opened
}

private func draft(_ outcome: String) throws -> Data {
    var charter = inboxCharter()
    charter.scorer = .exact(fields: ["decisions.choice"])
    charter.outcome = outcome
    return try CanonicalJSON.encode(charter)
}

@Test func charterProposalGoesLiveOnlyThroughItsGate() async throws {
    let opened = try await gatedHome()
    let workspace = opened.workspace
    let outcome = "Every new message is routed within ten minutes."

    await #expect(throws: WorkspaceError.self) {
        try await workspace.proposeCharter(
            steward: "st_inbox", charter: try draft(outcome), baseVersion: 2)
    }
    let proposal = try await workspace.proposeCharter(
        steward: "st_inbox", charter: try draft(outcome), baseVersion: 1, title: "Faster",
        reason: "Routing within an hour is too slow.")
    #expect(proposal.status == "open")
    #expect(proposal.candidateVersion == 2)
    #expect(proposal.reason == "Faster\nRouting within an hour is too slow.")
    #expect(proposal.author == "human:local")
    await #expect(throws: WorkspaceError.self) { try await workspace.acceptProposal(proposal.id) }

    let checked = try await workspace.checkProposal(proposal.id)
    let verdict = try #require(checked.verdict)
    #expect(verdict.passed)
    #expect(checked.status == "passed")
    #expect(checked.acceptable)

    let steward = try await workspace.acceptProposal(proposal.id)
    #expect(steward.charterVersion == 2)
    let charter = try Charter.load(from: try await workspace.charter("st_inbox"))
    #expect(charter.outcome == outcome)
    #expect(try await workspace.proposals(steward: "st_inbox").map(\.status) == ["accepted"])
    await #expect(throws: WorkspaceError.self) {
        try await workspace.rejectProposal(proposal.id)
    }
}

@Test func aFailedCharterGateNeedsAPersonToOverride() async throws {
    let opened = try await gatedHome()
    let workspace = opened.workspace
    let first = try await workspace.proposeCharter(
        steward: "st_inbox", charter: try draft("Route faster."), baseVersion: 1)
    let second = try await workspace.proposeCharter(
        steward: "st_inbox", charter: try draft("Route sooner."), baseVersion: 1)

    await #expect(throws: WorkspaceError.self) {
        try await workspace.overrideProposal(first.id, reason: "ship it")
    }
    await #expect(throws: WorkspaceError.rejected("an override needs a reason")) {
        try await workspace.overrideProposal(first.id, reason: "")
    }
    try await workspace.rejectProposal(second.id, reason: "duplicate")
    #expect(try await workspace.proposal(second.id)?.status == "rejected")
    await #expect(throws: WorkspaceError.notFound("prop_missing")) {
        try await workspace.checkProposal("prop_missing")
    }
}

private func proposeRoutine(_ opened: Opened, _ body: String) async throws -> String {
    let source = try RoutineSource(name: "tag-billing", language: .sh, content: body)
    let draft = try EventDraft(
        try source.propose(into: BlobStore(home: opened.home.url)), actor: .system,
        steward: StewardID(unchecked: "st_inbox"))
    _ = try await opened.workspace.sink.append(RuntimeEventDraft(draft))
    return source.version
}

@Test func routineVersionsGoLiveThroughTheirGateOrAnOverride() async throws {
    let opened = try await gatedHome()
    let workspace = opened.workspace
    let first = try await proposeRoutine(opened, "echo v1\n")

    let gated = try await workspace.gateRoutine(
        steward: "st_inbox", name: "tag-billing", version: first)

    #expect(gated.promoted == gated.verdict.passed)
    #expect(gated.promoted)
    #expect(
        try await workspace.routine(steward: "st_inbox", name: "tag-billing", version: first)?
            .gate == .live)
    let ledger = try await workspace.ledger()
    let gatedEvent = try #require(ledger.last { $0.type == "proposal.gated" })
    #expect(gatedEvent.payload.contains(first))
    await #expect(throws: WorkspaceError.self) {
        try await workspace.gateRoutine(steward: "st_inbox", name: "tag-billing", version: first)
    }

    let second = try await proposeRoutine(opened, "echo v2\n")
    await #expect(throws: WorkspaceError.rejected("an override needs a reason")) {
        try await workspace.overrideRoutine(
            steward: "st_inbox", name: "tag-billing", version: second, reason: "")
    }
    try await workspace.overrideRoutine(
        steward: "st_inbox", name: "tag-billing", version: second, reason: "urgent label fix")
    #expect(try await workspace.routines(steward: "st_inbox").first?.liveVersion == second)
    let promoted = try #require(try await workspace.ledger().last { $0.type == "routine.promoted" })
    #expect(promoted.actorKind == "human")
    #expect(try await workspace.ledger().last?.payload.contains("urgent label fix") == true)
}
