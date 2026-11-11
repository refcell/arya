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

/// `arya history ingest` records a pass per connection (here the example's placeholder binding
/// commands cannot start, so each records its error), and `arya steward onboarding` shows each
/// connection's history status.
@Test func historyIngestAndOnboardingShowIngestionStatus() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-cli-ingest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let charter = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("etc/examples/triage/charter.json")
    _ = await arya(home, "init")
    #expect(await arya(home, "steward", "create", "--charter", charter.path).0 == .ok)

    let (before, unread, _) = await arya(home, json: false, "steward", "onboarding", "st_triage")
    #expect(before == .ok)
    #expect(unread.contains("  history inbox: history not read yet."), "\(unread)")

    let (status, out, _) = await arya(home, "history", "ingest", "st_triage", "--binding", "inbox")
    #expect(status == .ok)
    let statuses = try JSONDecoder().decode([IngestionStatus].self, from: Data(out.utf8))
    #expect(statuses.map(\.connection) == ["inbox"])
    #expect(statuses.first?.passes == 1 && statuses.first?.records == 0)
    #expect(statuses.first?.lastError?.contains("inbox-mcp") == true, "\(statuses)")

    let (_, all, _) = await arya(home, json: false, "history", "ingest", "st_triage")
    #expect(all.split(separator: "\n").count == 3, "\(all)")
    let (_, text, _) = await arya(home, json: false, "steward", "onboarding", "st_triage")
    #expect(text.contains("  history inbox: 0 records; the last pass stopped:"), "\(text)")
}
