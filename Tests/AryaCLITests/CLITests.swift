import Foundation
import Testing

@testable import AryaCLI

@Test func stewardListPrintsATable() async {
    let (status, capture) = await runCLI(["steward", "list"])
    #expect(status == .ok)
    #expect(
        capture.out == [
            "ID         NAME                  STATE  VERSION  APPROVALS  LAST RUN",
            "st_triage  Support inbox triage  draft  1        1          -",
        ])
    #expect(capture.err.isEmpty)
}

@Test func stewardListJSONIsStable() async throws {
    let (status, capture) = await runCLI(["steward", "list", "--json"])
    #expect(status == .ok)
    #expect(
        capture.outText == """
            [
              {
                "charterVersion" : 1,
                "id" : "st_triage",
                "name" : "Support inbox triage",
                "pendingApprovals" : 1,
                "state" : "draft"
              }
            ]
            """)
}

@Test func everyListingSupportsJSON() async throws {
    let listings: [[String]] = [
        ["steward", "list"], ["approvals"], ["ledger", "tail"], ["ledger", "verify"], ["init"],
        ["steward", "show", "st_triage"], ["run", "st_triage"], ["approve", "ap_1"],
        ["steward", "pause", "st_triage"], ["steward", "resume", "st_triage"],
    ]
    for arguments in listings {
        let (status, capture) = await runCLI(arguments + ["--json"])
        #expect(status == .ok, "\(arguments)")
        let data = Data(capture.outText.utf8)
        #expect(throws: Never.self, "\(arguments)") { try JSONSerialization.jsonObject(with: data) }
    }
}

@Test func argumentsReachTheBackend() async {
    let backend = FakeBackend()
    _ = await runCLI(["steward", "create", "--charter", "triage.json"], backend: backend)
    _ = await runCLI(["run", "st_triage", "--input", "hello"], backend: backend)
    _ = await runCLI(["approvals", "--steward", "st_triage", "--all"], backend: backend)
    _ = await runCLI(["approve", "ap_1", "--note", "fine"], backend: backend)
    _ = await runCLI(["deny", "ap_2"], backend: backend)
    _ = await runCLI(["ledger", "tail", "-n", "5"], backend: backend)
    #expect(
        backend.calls == [
            "create triage.json", "run st_triage hello", "approvals st_triage all",
            "decide ap_1 grant fine", "decide ap_2 deny -", "tail 5 -",
        ])
}

@Test func runReportShowsDispositions() async {
    let (status, capture) = await runCLI(["run", "st_triage"])
    #expect(status == .ok)
    #expect(
        capture.out == [
            "run run_1 (st_triage) completed",
            "summary: routed one message",
            "decision: billing",
            "action a1: label inbox:MSG-1 -> executed",
            "action a2: reply inbox:MSG-1 -> held (approval ap_1)",
        ])
}

@Test func failedRunExitsNonZero() async {
    let backend = FakeBackend()
    backend.runStatus = "failed"
    let (status, capture) = await runCLI(["run", "st_triage"], backend: backend)
    #expect(status == .failure)
    #expect(capture.err == ["arya: run run_1 failed"])
}

@Test func brokenLedgerExitsNonZero() async {
    let backend = FakeBackend()
    backend.verifyResult = VerifyReport(
        isValid: false, events: 9,
        firstBreak: .init(seq: 4, reason: "hash mismatch"))
    let (status, capture) = await runCLI(["ledger", "verify"], backend: backend)
    #expect(status == .failure)
    #expect(capture.out == ["ledger broken at seq 4: hash mismatch (9 events)"])
}

@Test func notFoundMapsToItsExitStatus() async {
    let (status, capture) = await runCLI(["steward", "show", "st_missing"])
    #expect(status == .noInput)
    #expect(capture.err == ["arya: not found: steward st_missing"])
}

@Test func usageErrorsPrintUsage() async {
    let (status, capture) = await runCLI(["approve"])
    #expect(status == .usage)
    #expect(
        capture.err == [
            "arya: missing <approval>", "usage: arya approve <approval> [--note <text>]",
            "run `arya --help` for the list of commands",
        ])
    #expect(capture.out.isEmpty)
}

@Test func helpListsEveryCommand() async {
    let (status, capture) = await runCLI(["--help"])
    #expect(status == .ok)
    for spec in CommandTable.all {
        #expect(capture.outText.contains("  \(spec.path.joined(separator: " "))  "), "\(spec.id)")
    }
    let (_, one) = await runCLI(["help", "ledger", "tail"])
    #expect(one.out.first == "usage: arya ledger tail [--count <n>] [--steward <id>]")
    #expect(one.outText.contains("-n, --count <n>  how many events (default 20)"))
}

@Test func homeResolutionOrder() {
    let user = URL(fileURLWithPath: "/u", isDirectory: true)
    let work = URL(fileURLWithPath: "/w", isDirectory: true)
    func resolve(_ flag: String?, _ env: [String: String] = [:]) -> String {
        Home.resolve(flag: flag, environment: env, userHome: user, workingDirectory: work).path
    }
    #expect(resolve(nil) == "/u/Library/Application Support/arya")
    #expect(resolve(nil, ["ARYA_HOME": ""]) == "/u/Library/Application Support/arya")
    #expect(resolve(nil, ["ARYA_HOME": "/e"]) == "/e")
    #expect(resolve("/f", ["ARYA_HOME": "/e"]) == "/f")
    #expect(resolve("rel/home") == "/w/rel/home")
    #expect(resolve("~/h") == "/u/h")
}

@Test func backendOpensTheResolvedHome() async {
    let seen = Capture()
    let backend = FakeBackend()
    _ = await CLI.run(
        ["--home", "demo", "steward", "list"], context: testContext, output: Capture().output,
        backend: { home in
            seen.output.write(home.path)
            return backend
        })
    #expect(seen.out == ["/work/demo"])
}

@Test func tableAlignsColumnsWithoutTrailingSpaces() {
    let table = Table(headers: ["a", "bb"], rows: [["xxx", "y"], ["z", ""]])
    #expect(table.lines == ["A    BB", "xxx  y", "z"])
}

@Test func pauseAndResumeReachTheBackend() async {
    let backend = FakeBackend()
    #expect(await runCLI(["steward", "pause", "st_triage"], backend: backend).0 == .ok)
    #expect(await runCLI(["steward", "resume", "st_triage"], backend: backend).0 == .ok)
    #expect(backend.calls == ["pause st_triage", "resume st_triage"])
    #expect(await runCLI(["steward", "pause", "st_missing"]).0 != .ok)
}

@Test func runCorrectAndRetractReachTheBackend() async {
    let backend = FakeBackend()
    let corrected = await runCLI(
        ["run", "correct", "run_1", "--choice", "refunds", "--note", "Refunds own these."],
        backend: backend)
    #expect(corrected.0 == .ok)
    #expect(corrected.1.outText.contains("noted as mem_2"))
    #expect(await runCLI(["retract", "mem_2", "--reason", "wrong"], backend: backend).0 == .ok)
    #expect(
        backend.calls == ["correct run run_1 refunds Refunds own these.", "retract mem_2 wrong"])
    #expect(await runCLI(["run", "correct", "run_1"]).0 == .usage)
}

@Test func readinessRendersTheSentenceAndRegressions() async {
    let backend = FakeBackend()
    let (status, capture) = await runCLI(["readiness", "prop_1"], backend: backend)
    #expect(status == .ok)
    #expect(capture.outText.contains("prop_1 (st_triage): Not ready: case-0005 would regress"))
    #expect(capture.outText.contains("2 recent runs replayed"))
    #expect(backend.calls == ["readiness prop_1"])
}

@Test func runReportsShowTheirCrew() {
    let lines = TextRender.run(
        RunReport(
            run: "run_2", steward: "st_triage", status: "completed", summary: "drafted",
            decisions: [], actions: [], parent: "run_1", crew: ["run_3"], join: "run_4"))
    #expect(lines.contains("delegated by: run_1"))
    #expect(lines.contains("crew: run_3"))
    #expect(lines.contains("joined by: run_4"))
}

@Test func fleetShowsEachOutcomeAgainstItsTarget() async {
    let backend = FakeBackend()
    let (status, capture) = await runCLI(["fleet"], backend: backend)
    #expect(status == .ok)
    #expect(capture.outText.contains("routing_accuracy"))
    #expect(capture.outText.contains("0.96"))
    #expect(capture.outText.contains("on track"))
    #expect(backend.calls == ["fleet"])
}
