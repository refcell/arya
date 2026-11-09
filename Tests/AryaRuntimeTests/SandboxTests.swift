import AryaAdapters
import AryaCore
import AryaMemory
import Foundation
import Testing

@testable import AryaRuntime

private func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-\(name)-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func theProfileConfinesWritesAndNetwork() throws {
    let work = try tempDir("sbx-profile")
    defer { try? FileManager.default.removeItem(at: work) }
    let closed = try Sandbox(workdir: work.path)
    #expect(closed.profile.contains("(deny network*)"))
    #expect(closed.profile.contains("(allow file-write* (subpath \"\(closed.workdir)\"))"))
    #expect(try !Sandbox(workdir: work.path, network: true).profile.contains("deny network"))
    let wrapped = closed.wrap("server", ["--stdio"])
    #expect(wrapped.command == "/usr/bin/sandbox-exec")
    #expect(wrapped.args == ["-p", closed.profile, "/usr/bin/env", "server", "--stdio"])
}

@Test(.enabled(if: Sandbox.available)) func sandboxedRoutinesWriteOnlyInTheirWorkdir() throws {
    let work = try tempDir("sbx-routine")
    let outside = try tempDir("sbx-outside")
    defer {
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.removeItem(at: outside)
    }
    let script = """
        echo in > inside.txt && echo wrote-inside
        echo out > "$1/escaped.txt" 2>/dev/null || echo blocked-outside
        echo "name=$ARYA_ROUTINE script=${ARYA_SANDBOX_SCRIPT:-unset}"
        """
    let invocation = RoutineInvocation(
        name: "probe", version: "v1", content: script, arguments: [outside.path], workdir: work,
        timeoutSeconds: 20)
    let outcome = try SandboxedRoutineRunner().run(invocation)
    #expect(outcome.status == .exited)
    #expect(outcome.exitCode == 0)
    #expect(outcome.stdout.contains("wrote-inside"))
    #expect(outcome.stdout.contains("blocked-outside"))
    #expect(outcome.stdout.contains("name=probe script=unset"))
    #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("inside.txt").path))
    #expect(
        !FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.txt").path))
}

@Test func sandboxedRunsRecordTheSandboxAndConfineProxies() async throws {
    let harness = RunHarness(
        script: FakeScript(runs: [FakeScript.Run(result: triageResult)]),
        proxy: BindingProxyLaunch(command: "/usr/local/bin/arya", args: ["proxy"]),
        workdirRoot: try tempDir("sbx-run").path, sandbox: true)
    var charter = triageCharter()
    charter.bindings[0].network = true
    let outcome = try await harness.start(charter: charter)
    let started = try #require(try await harness.last("run.started"))
    let sandbox = started.payload["sandbox"]
    if Sandbox.available {
        #expect(sandbox?["kind"] == "sandbox-exec")
        #expect(sandbox?["network"] == ["tracker"])
        let workdir = try #require(sandbox?["workdir"]?.stringValue)
        #expect(workdir.hasSuffix(outcome.run.rawValue))
    } else {
        #expect(sandbox == nil)
    }
    // Unsandboxed engines record nothing.
    let plain = RunHarness(FakeScript.Run(result: triageResult))
    _ = try await plain.start()
    let plainStarted = try #require(try await plain.last("run.started"))
    #expect(plainStarted.payload["sandbox"] == nil)
}

@Test func bindingNetworkIsOmittedUnlessAllowed() throws {
    let plain = try CanonicalJSON.jsonValue(CharterBinding.mcp("tracker", command: "srv"))
    #expect(plain["network"] == nil)
    var open = CharterBinding.mcp("tracker", command: "srv")
    open.network = true
    let json = try CanonicalJSON.jsonValue(open)
    #expect(json["network"] == true)
    #expect(try CanonicalJSON.decode(CharterBinding.self, from: CanonicalJSON.encode(open)) == open)
}

@Test func proxyArgumentsCarryTheSandbox() throws {
    let parsed = try BindingProxyArguments(
        parsing: [
            "--steward", "st_triage", "--run", "run_01", "--binding", "tracker",
            "--sandbox", "/tmp/work",
        ])
    #expect(parsed.sandbox == "/tmp/work")
    let servers = BindingProxyLaunch(command: "arya", args: ["proxy"]).servers(
        charter: triageCharter(), run: RunID(unchecked: "run_01"), recorded: nil,
        sandbox: "/tmp/work")
    #expect(servers.first?.args.suffix(2) == ["--sandbox", "/tmp/work"])
}
