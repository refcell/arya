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
    let findings = try await workspace.findings(steward: "st_inbox")
    #expect(findings.filter { $0.title.hasPrefix("Access refused") }.count == 1)

    await #expect(throws: WorkspaceError.self) {
        try await workspace.revokeAccess("use", on: "*", from: "team:support")
    }
    try await workspace.setTeam("support", members: [])
    #expect(try await workspace.access().teams.isEmpty)
}
