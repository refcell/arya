import Arya
import Foundation
import Testing

@testable import AryaCLI

/// Runs `arya --home HOME --json ARGS` against a real workspace and returns its status and output.
private func arya(_ home: URL, _ arguments: String...) async -> (AryaCLI.ExitStatus, String, String)
{
    let capture = Capture()
    let status = await CLI.run(
        ["--home", home.path, "--json"] + arguments, context: testContext,
        output: capture.output, backend: { WorkspaceBackend(home: $0) })
    return (status, capture.outText, capture.errText)
}

@Test func governanceCommandsParse() throws {
    for (words, id) in [
        (["steward", "policy", "st_triage"], CommandID.stewardPolicy),
        (["undo", "run_1"], .undo), (["undo", "run_1", "a1", "--reason", "wrong"], .undo),
        (["retention", "--days", "30"], .retention), (["retention", "apply"], .retentionApply),
        (["encryption", "--enable"], .encryption),
        (["export", "st_triage", "--signed", "--out", "/tmp/x"], .export),
        (["export", "verify", "/tmp/x"], .exportVerify), (["import", "/tmp/x"], .importExport),
    ] {
        let parser = ArgumentParser(commands: CommandTable.all)
        guard case .run(let invocation) = try parser.parse(words) else {
            Issue.record("\(words) did not parse to a command")
            continue
        }
        #expect(invocation.command == id)
    }
}

@Test func signedExportVerifiesAndImportsIntoAnotherHome() async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-cli-gov-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let source = base.appendingPathComponent("source")
    let target = base.appendingPathComponent("target")
    let charter = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("etc/examples/triage/charter.json")
    _ = await arya(source, "init")
    #expect(await arya(source, "steward", "create", "--charter", charter.path).0 == .ok)

    let (policyStatus, policy, _) = await arya(source, "steward", "policy", "st_triage")
    #expect(policyStatus == .ok)
    #expect(policy.contains("person:sam"))

    let (setStatus, set, _) = await arya(
        source, "retention", "--steward", "st_triage", "--days", "90")
    #expect(setStatus == .ok)
    #expect(set.contains("st_triage") && set.contains("90"))
    #expect(await arya(source, "retention", "--steward", "st_triage").0 == .usage)

    let out = base.appendingPathComponent("export").path
    #expect(await arya(source, "export", "st_triage", "--signed", "--out", out).0 == .ok)
    let (verifyStatus, verified, _) = await arya(source, "export", "verify", out)
    #expect(verifyStatus == .ok)
    #expect(verified.contains("\"issues\""))

    _ = await arya(target, "init")
    let (importStatus, imported, _) = await arya(target, "import", out)
    #expect(importStatus == .ok)
    #expect(imported.contains("st_triage"))
    #expect(await arya(target, "import", out).0 != .ok)

    let events = URL(fileURLWithPath: out).appendingPathComponent("events.jsonl")
    var text = try String(contentsOf: events, encoding: .utf8)
    text = text.replacingOccurrences(of: "billing", with: "shipping")
    try text.write(to: events, atomically: true, encoding: .utf8)
    #expect(await arya(source, "export", "verify", out).0 != .ok)

    let (encStatus, encryption, _) = await arya(source, "encryption")
    #expect(encStatus == .ok)
    #expect(encryption.contains("\"enabled\"") && encryption.contains("false"))
}
