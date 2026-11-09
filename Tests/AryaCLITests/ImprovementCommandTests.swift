import Foundation
import Testing

@testable import AryaCLI

@Test func improvementArgumentsReachTheBackend() async {
    let backend = FakeBackend()
    let lines: [[String]] = [
        ["casebook", "import", "st_triage", "book.jsonl"],
        ["casebook", "import", "st_triage", "book.jsonl", "--name", "past"],
        ["casebook", "list", "--steward", "st_triage"],
        ["rehearse", "st_triage"],
        ["rehearse", "st_triage", "--casebook", "past"],
        ["correct", "st_triage", "case-0006", "--choice", "billing"],
        ["ready", "st_triage"],
        ["propose", "st_triage", "--charter", "v2.json"],
        ["proposals"],
        ["metrics", "st_triage", "--metric", "routed_within_1h"],
        ["memory", "st_triage", "--all"],
        ["routines", "st_triage"],
        ["replay", "run_1"],
        ["binding-proxy", "--run", "run_1", "--binding", "inbox"],
    ]
    for line in lines {
        let (status, capture) = await runCLI(line, backend: backend)
        #expect(status == .ok, "\(line): \(capture.errText)")
    }
    #expect(
        backend.calls == [
            "import st_triage book.jsonl -", "import st_triage book.jsonl past",
            "casebooks st_triage", "rehearse st_triage -", "rehearse st_triage past",
            "correct st_triage case-0006 billing -", "ready st_triage",
            "propose st_triage v2.json", "proposals -", "metrics st_triage routed_within_1h",
            "memory st_triage all", "routines st_triage", "replay run_1", "proxy run_1 inbox",
        ])
}

@Test func correctNeedsAChoiceOrANote() async {
    let backend = FakeBackend()
    let (status, capture) = await runCLI(["correct", "st_triage", "case-0006"], backend: backend)
    #expect(status == .usage)
    #expect(capture.err.first == "arya: give --choice, --note, or both")
    #expect(backend.calls.isEmpty)
}

@Test func rehearsalTextListsFailingCases() async {
    let (_, capture) = await runCLI(["rehearse", "st_triage"])
    #expect(
        capture.out == [
            "rehearsal reh_1: 7 of 8 cases pass (score 88%) on casebook",
            "  case-0006  score 0%",
        ])
}

@Test func rehearsalJSONHasTheFieldsE2EReads() async throws {
    let (_, capture) = await runCLI(["rehearse", "st_triage", "--json"])
    let object = try #require(
        try JSONSerialization.jsonObject(with: Data(capture.outText.utf8)) as? [String: Any])
    #expect(object["passed"] as? Int == 7)
    #expect(object["total"] as? Int == 8)
    #expect(object["failed"] as? [String] == ["case-0006"])
}

@Test func divergentReplayFails() async {
    let backend = FakeBackend()
    backend.replayDiverges = true
    let (status, capture) = await runCLI(["replay", "run_1"], backend: backend)
    #expect(status == .failure)
    #expect(capture.out.first == "replay of run_1 diverged in 1 event(s):")
    #expect(capture.err == ["arya: replay of run_1 diverged"])
    let (clean, output) = await runCLI(["replay", "run_1"])
    #expect(clean == .ok)
    #expect(output.out == ["replay of run_1: 12 events, zero divergence"])
}

@Test func improvementListingsSupportJSON() async {
    let listings: [[String]] = [
        ["casebook", "list"], ["proposals"], ["metrics", "st_triage"], ["memory", "st_triage"],
        ["routines", "st_triage"], ["replay", "run_1"], ["ready", "st_triage"],
        ["correct", "st_triage", "case-0006", "--note", "n"],
        ["propose", "st_triage", "--charter", "c.json"],
        ["casebook", "import", "st_triage", "b.jsonl"],
    ]
    for arguments in listings {
        let (status, capture) = await runCLI(arguments + ["--json"])
        #expect(status == .ok, "\(arguments)")
        let data = Data(capture.outText.utf8)
        #expect(throws: Never.self, "\(arguments)") { try JSONSerialization.jsonObject(with: data) }
    }
}

@Test func unlandedImprovementCallsNameTheFacadeCall() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-cli-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let capture = Capture()
    let status = await CLI.run(
        ["--home", home.path, "rehearse", "st_triage"], context: testContext,
        output: capture.output, backend: { WorkspaceBackend(home: $0) })
    #expect(status == .unavailable)
    #expect(capture.errText.contains("Workspace.rehearse"))
}
