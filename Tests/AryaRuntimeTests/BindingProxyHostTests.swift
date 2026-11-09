import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private let launch = BindingProxyLaunch(command: "/opt/arya/bin/arya", args: ["binding-proxy"])

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-proxy-\(ProcessInfo.processInfo.globallyUniqueString)")
}

/// The `tools` of the `run/start` request the run sent.
private func startTools(_ harness: RunHarness) async throws -> [JSONValue] {
    let sent = try await harness.sink.events(from: 1).first {
        $0.type == RunEventType.adapterEvent && $0.payload["message"]?["method"] == "run/start"
    }
    return try #require(sent?.payload["message"]?["params"]?["tools"]?.arrayValue)
}

@Test func argumentsParse() throws {
    let parsed = try BindingProxyArguments(
        parsing: ["--steward", "st_triage", "--run", "run_01", "--binding", "tracker"])
    #expect(parsed.binding == "tracker")
    #expect(parsed.recorded == nil)
    #expect(throws: BindingProxyError.self) {
        try BindingProxyArguments(parsing: ["--steward", "st_triage", "--run"])
    }
    #expect(throws: BindingProxyError.self) {
        try BindingProxyArguments(parsing: ["--steward", "st_triage", "--run", "r", "--x", "y"])
    }
}

@Test func liveRunsHandTheHarnessOneProxyPerReadBinding() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = RunHarness(
        script: FakeScript(runs: [FakeScript.Run(result: triageResult)]), proxy: launch,
        workdirRoot: root.path)
    let outcome = try await harness.start()
    let tools = try await startTools(harness)
    #expect(tools.count == 1)
    #expect(tools[0]["name"] == "tracker")
    #expect(tools[0]["command"] == "/opt/arya/bin/arya")
    #expect(
        tools[0]["args"]
            == .array(
                [
                    "binding-proxy", "--steward", "st_triage", "--run", outcome.run.rawValue,
                    "--binding", "tracker",
                ].map { .string($0) }))
}

@Test func rehearsalProxiesAnswerFromTheCaseRecordings() async throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let harness = RunHarness(
        script: FakeScript(runs: [FakeScript.Run(result: triageResult)]), proxy: launch,
        workdirRoot: root.path)
    let recordings = [
        RecordedToolResult(tool: "tracker.get", input: ["id": "ISSUE-7"], output: ["title": "x"])
    ]
    let outcome = try await harness.start(.rehearsal(CaseContext(toolResults: recordings)))
    let args = try #require(try await startTools(harness).first?["args"]?.arrayValue)
    let file = root.appendingPathComponent(outcome.run.rawValue)
        .appendingPathComponent("tool-results.json")
    #expect(args.suffix(2) == ["--recorded", .string(file.path)])

    // The proxy process for that run answers from the file and records into the ledger.
    let arguments = try BindingProxyArguments(parsing: args.dropFirst().compactMap(\.stringValue))
    let proxy = try await BindingProxyHost.proxy(arguments, sink: harness.sink)
    let reply = try await proxy.handle(
        .request(
            RPCRequest(
                id: .int(1), method: "tools/call",
                params: ["name": "get", "arguments": ["id": "ISSUE-7"]])))
    guard case .response(let response)? = reply, case .success(let value) = response.outcome
    else {
        Issue.record("tools/call failed")
        return
    }
    #expect(value["structuredContent"]?["title"] == "x")
    let result = try #require(try await harness.last("run.tool.result"))
    #expect(result.draft.run == outcome.run)
}

@Test func hostRefusesUnknownStewardsAndBindings() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    try await harness.lifecycle.create(triageCharter())
    for (steward, binding, expected) in [
        ("st_ghost", "tracker", BindingProxyError.unknownSteward(StewardID(unchecked: "st_ghost"))),
        ("st_triage", "mail", BindingProxyError.unknownBinding("mail")),
    ] {
        let arguments = try BindingProxyArguments(
            parsing: ["--steward", steward, "--run", "run_01", "--binding", binding])
        await #expect(throws: expected) {
            _ = try await BindingProxyHost.proxy(arguments, sink: harness.sink)
        }
    }
}
