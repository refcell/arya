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

@Test func messageIntentsHonorGrants() async throws {
    let opened = try await Opened([
        FakeScript.Run(result: liveResult), FakeScript.Run(result: liveResult),
        FakeScript.Run(result: liveResult), FakeScript.Run(result: liveResult),
        FakeScript.Run(result: liveResult), FakeScript.Run(result: liveResult),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try peopleCharterJSON())
    // No grants in the home: anyone bound may message.
    _ = try await workspace.message(steward: "st_inbox", text: "Any news?", by: "ana")

    // Once there are grants, asking still only needs the binding; correcting needs use.
    try await workspace.grantAccess("view", on: "steward:st_inbox", to: "sam")
    _ = try await workspace.message(steward: "st_inbox", text: "Status?", by: "ana")
    await #expect(
        throws: WorkspaceError.rejected(
            "person:ana has no use grant to correct st_inbox or its tools; nobody holds one")
    ) {
        try await workspace.message(
            steward: "st_inbox", text: "Route billing to finance", intent: "correct", by: "ana")
    }
    let refusal = try #require(try await workspace.access().refusals.first)
    #expect(refusal.person == "person:ana" && refusal.action == "message.correct")
    #expect(refusal.level == "use")

    // Sam may ask but not correct without use.
    _ = try await workspace.message(steward: "st_inbox", text: "Status?", by: "sam")
    await #expect(throws: WorkspaceError.self) {
        try await workspace.message(
            steward: "st_inbox", text: "Route billing to finance", intent: "correct", by: "sam")
    }
    // A hand-off is let in: runtime gates the actions its run takes on Sam's use grant.
    _ = try await workspace.message(
        steward: "st_inbox", text: "Take MSG-9", intent: "handoff", by: "sam")
    try await workspace.grantAccess("use", on: "steward:st_inbox", to: "sam")
    _ = try await workspace.message(
        steward: "st_inbox", text: "Route billing to finance", intent: "correct", by: "sam")
    // A use grant on one of its tools is enough to correct it.
    try await workspace.grantAccess("use", on: "tool:inbox.label", to: "ana")
    _ = try await workspace.message(
        steward: "st_inbox", text: "Label refunds as billing", intent: "correct", by: "ana")
    // The owner is never limited.
    _ = try await workspace.message(steward: "st_inbox", text: "Status?")
}
