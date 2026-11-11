import AryaAdapters
import AryaCore
import AryaFakeAdapter
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private func peopleCharterJSON() throws -> Data {
    var charter = inboxCharter()
    charter.bindings += [.person("sam", channel: "local"), .person("ana", channel: "local")]
    return try CanonicalJSON.encode(charter)
}

@Test func grantsAndTeamsAreGatedUndoableAndEnforced() async throws {
    let opened = try await Opened([
        FakeScript.Run(result: liveResult), FakeScript.Run(result: liveResult),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try peopleCharterJSON())
    let empty = try await workspace.access()
    #expect(!empty.enforced && empty.people == ["person:ana", "person:sam"])
    #expect(empty.resources.map(\.id).contains("tool:inbox.label"))

    try await workspace.setTeam("support", name: "Support", members: ["sam"])
    var access = try await workspace.grantAccess("use", on: "tool:inbox.label", to: "team:support")
    #expect(access.enforced)
    #expect(
        access.teams == [
            AccessTeamSummary(id: "team:support", name: "Support", members: ["person:sam"])
        ])
    #expect(access.grants.map(\.resource) == ["tool:inbox.label"])
    #expect(access.lastChange?.text == "Granted use on tool:inbox.label to team:support")
    #expect(access.lastChange?.kind == "granted")
    #expect(access.lastChange?.grant?.resource == "tool:inbox.label")

    // Only the owner or an access admin changes access.
    await #expect(throws: WorkspaceError.self) {
        try await workspace.grantAccess("use", on: "*", to: "sam", as: "sam")
    }
    // Undo takes a change back by its inverse.
    access = try await workspace.grantAccess("use", on: "connection:inbox", to: "ana")
    access = try await workspace.undoAccess(try #require(access.lastChange?.seq))
    #expect(access.grants.map(\.subject) == ["team:support"])
    #expect(
        access.lastChange?.text.hasPrefix("Revoked use on connection:inbox from person:ana") == true
    )

    // sam's message: label goes through; route is refused and listed (reply the charter denies).
    let receipt = try await workspace.message(steward: "st_inbox", text: "Refund please", by: "sam")
    #expect(receipt.run != nil)
    access = try await workspace.access()
    #expect(access.refusals.map(\.action) == ["route"])
    #expect(access.refusals.first?.reason == "person:sam has no use grant for route on inbox")
    #expect(access.refusals.first?.steward == "st_inbox")
    #expect(access.refusals.first?.resources.contains("connection:inbox") == true)
    #expect(access.refusals.first?.asked?.contains("Refund please") == true)
    // The label went through on Support's grant, and the grant says so.
    let used = try #require(access.grants.first { $0.subject == "team:support" })
    #expect(used.uses == 1)
    #expect(used.lastUse?.person == "person:sam" && used.lastUse?.action == "label")
    #expect(used.lastUse?.run == receipt.run?.id)
    #expect(access.enforcedSince != nil && access.enforcement == nil)
    let findings = try await workspace.findings(steward: "st_inbox")
    #expect(findings.filter { $0.title.hasPrefix("Access refused") }.count == 1)

    await #expect(throws: WorkspaceError.self) {
        try await workspace.revokeAccess("use", on: "*", from: "team:support")
    }
    try await workspace.setTeam("support", members: [])
    #expect(try await workspace.access().teams.isEmpty)
}

/// Enforcement fails closed (decision 0066): revoking the last grant leaves it on, so with no
/// grant in force every correction and action that needs one is refused. Only an explicit,
/// undoable `setAccessEnforcement(false)` turns it off, and a later grant turns it on again.
@Test func revokingTheLastGrantKeepsEnforcementOn() async throws {
    let opened = try await Opened(Array(repeating: FakeScript.Run(result: liveResult), count: 4))
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try peopleCharterJSON())
    try await workspace.grantAccess("use", on: "steward:st_inbox", to: "sam")
    _ = try await workspace.message(
        steward: "st_inbox", text: "Route billing to finance", intent: "correct", by: "sam")

    var access = try await workspace.revokeAccess("use", on: "steward:st_inbox", from: "sam")
    #expect(access.enforced && access.grants.isEmpty && access.teams.isEmpty)
    await #expect(
        throws: WorkspaceError.rejected(
            "person:sam has no use grant to correct st_inbox or its tools; nobody holds one")
    ) {
        try await workspace.message(
            steward: "st_inbox", text: "Route billing to finance", intent: "correct", by: "sam")
    }
    // A run on sam's behalf: both actions that call the inbox are refused before they run.
    let executed = await opened.executor.requests.count
    _ = try await workspace.message(steward: "st_inbox", text: "Refund please", by: "sam")
    access = try await workspace.access()
    #expect(Set(access.refusals.prefix(2).map(\.action)) == ["label", "route"])
    #expect(await opened.executor.requests.count == executed)

    // Off only by an explicit change; it is recorded and undoable.
    await #expect(throws: WorkspaceError.rejected("enforcement is already on")) {
        try await workspace.setAccessEnforcement(true)
    }
    await #expect(throws: WorkspaceError.self) {
        try await workspace.setAccessEnforcement(false, as: "sam")
    }
    access = try await workspace.setAccessEnforcement(false)
    #expect(!access.enforced && access.lastChange?.text == "Turned enforcement off")
    #expect(access.lastChange?.kind == "enforcement" && access.lastChange?.undoable == true)
    _ = try await workspace.message(
        steward: "st_inbox", text: "Route billing to finance", intent: "correct", by: "sam")
    access = try await workspace.undoAccess(try #require(access.lastChange?.seq))
    #expect(access.enforced && access.lastChange?.text == "Turned enforcement on")
    await #expect(throws: WorkspaceError.self) {
        try await workspace.message(
            steward: "st_inbox", text: "Route billing to finance", intent: "correct", by: "sam")
    }

    // Off again, then a new grant: enforcement is back on.
    _ = try await workspace.setAccessEnforcement(false)
    access = try await workspace.grantAccess("view", on: "steward:st_inbox", to: "ana")
    #expect(access.enforced)
}
