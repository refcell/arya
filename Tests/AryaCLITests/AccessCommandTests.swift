import Arya
import Foundation
import Testing

@testable import AryaCLI

/// Runs `arya --home HOME [--json] ARGS` against a real workspace.
private func arya(_ home: URL, json: Bool = true, _ arguments: String...) async
    -> (AryaCLI.ExitStatus, String, String)
{
    let capture = Capture()
    let status = await CLI.run(
        ["--home", home.path] + (json ? ["--json"] : []) + arguments, context: testContext,
        output: capture.output, backend: { WorkspaceBackend(home: $0) })
    return (status, capture.outText, capture.errText)
}

@Test func accessCommandsParse() throws {
    for (words, id) in [
        (["access", "list"], CommandID.accessList),
        (["access", "list", "--refusals", "5"], .accessList),
        (["access", "grant", "use", "connection:crm", "team:support"], .accessGrant),
        (["access", "grant", "view", "*", "person:sam", "--as", "person:ana"], .accessGrant),
        (["access", "revoke", "use", "connection:crm", "team:support"], .accessRevoke),
        (["access", "team", "support", "person:sam,person:ana", "--name", "Support"], .accessTeam),
        (["access", "team", "support"], .accessTeam),
        (["access", "undo", "42"], .accessUndo),
    ] {
        let parser = ArgumentParser(commands: CommandTable.all)
        guard case .run(let invocation) = try parser.parse(words) else {
            Issue.record("\(words) did not parse to a command")
            continue
        }
        #expect(invocation.command == id)
    }
}

@Test func accessGrantListTeamAndUndoThroughTheCLI() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-cli-access-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let charter = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("etc/examples/triage/charter.json")
    _ = await arya(home, "init")
    #expect(await arya(home, "steward", "create", "--charter", charter.path).0 == .ok)

    let (emptyStatus, empty, _) = await arya(home, json: false, "access", "list")
    #expect(emptyStatus == .ok)
    #expect(empty.contains("nothing is enforced"))

    #expect(
        await arya(home, "access", "team", "support", "person:sam", "--name", "Support").0 == .ok)
    let (grantStatus, granted, _) = await arya(
        home, "access", "grant", "approve", "steward:st_triage", "team:support")
    #expect(grantStatus == .ok)
    let overview = try JSONDecoder().decode(AccessOverview.self, from: Data(granted.utf8))
    #expect(overview.enforced)
    #expect(overview.grants.map(\.subject) == ["team:support"])
    let seq = try #require(overview.lastChange?.seq)

    let (listStatus, list, _) = await arya(home, json: false, "access", "list")
    #expect(listStatus == .ok)
    #expect(list.contains("team:support may approve on steward:st_triage"))
    #expect(list.contains("arya access undo \(seq)"))

    // Bad input is a usage or input error, not a crash.
    #expect(await arya(home, "access", "grant", "own", "*", "person:sam").0 != .ok)
    #expect(await arya(home, "access", "undo", "x").0 == .usage)
    // Only the owner changes access.
    #expect(
        await arya(home, "access", "grant", "view", "*", "person:sam", "--as", "person:sam").0
            != .ok)

    let (undoStatus, undone, _) = await arya(home, "access", "undo", String(seq))
    #expect(undoStatus == .ok)
    let after = try JSONDecoder().decode(AccessOverview.self, from: Data(undone.utf8))
    #expect(after.grants.isEmpty)

    // Undoing the last grant leaves enforcement on (decision 0066); only `enforce off` ends it.
    #expect(await arya(home, "access", "team", "support").0 == .ok)
    let (_, closed, _) = await arya(home, json: false, "access", "list")
    #expect(closed.contains("enforced. With none in force, anything that needs a grant is refused"))
    #expect(await arya(home, "access", "enforce", "maybe").0 == .usage)
    let (offStatus, off, _) = await arya(home, "access", "enforce", "off")
    #expect(offStatus == .ok)
    #expect(try !JSONDecoder().decode(AccessOverview.self, from: Data(off.utf8)).enforced)
    #expect(await arya(home, "access", "enforce", "off").0 != .ok)
    #expect(await arya(home, "access", "enforce", "on").0 == .ok)
}
