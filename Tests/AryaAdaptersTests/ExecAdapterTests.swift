import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// A temporary directory holding a shell script that stands in for a command-line agent. The
/// directory is removed when the agent goes away.
final class FakeAgent: Sendable {
    let directory: URL
    let script: URL

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-exec-\(UInt64.random(in: 0...UInt64.max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        script = directory.appendingPathComponent("agent.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func profile(
        promptVia: PromptDelivery = .stdin, parse: OutputParser = .text,
        mcpConfig: MCPConfigDelivery = .none, args: [String] = []
    ) -> AdapterProfile {
        AdapterProfile(
            kind: .exec, command: script.path, args: ["medium": args], promptVia: promptVia,
            parse: parse, mcpConfig: mcpConfig)
    }

    func start(_ text: String = "triage ISSUE-1", schema: JSONValue? = nil) -> RunStartParams {
        RunStartParams(
            run: "run_e1", instructions: "Label new issues.",
            input: RunInput(kind: .case, text: text),
            workdir: directory.path,
            tools: [ToolServer(name: "tracker", command: "arya", args: ["binding-proxy"])],
            resultSchema: schema)
    }
}

/// Runs one exec run in process and returns its updates up to the result.
func execRun(_ agent: FakeAgent, _ profile: AdapterProfile, schema: JSONValue? = nil)
    async throws -> [AdapterUpdate]
{
    let (transport, endpoint) = InMemoryPipe.make()
    let server = ExecAdapterServer(
        profile: profile, environment: ["PATH": "/usr/bin:/bin"], endpoint: endpoint)
    Task { await server.serve() }
    let adapter = AdapterConnection(transport: transport, timeouts: Sample.fast)
    _ = try await adapter.initialize(InitializeParams(client: Sample.client))
    _ = try await adapter.start(agent.start(schema: schema))
    let updates = await collect(adapter, until: \.isResult)
    try await adapter.shutdown()
    return updates
}

@Test func textAgentResultComesFromTheLastJSONBlock() async throws {
    let agent = try FakeAgent(
        """
        prompt=$(cat)
        case "$prompt" in *"triage ISSUE-1"*) ;; *) exit 9 ;; esac
        echo "Reading the issue."
        printf '```json\\n{"summary":"Labeled.","decisions":[{"id":"d1","choice":"bug"}]}\\n```\\n'
        """)
    let updates = try await execRun(agent, agent.profile())
    let result = try #require(updates.compactMap(\.result).first)
    #expect(result.status == .completed)
    #expect(try result.decodedResult().decisions.map(\.choice) == ["bug"])
    let message = updates.compactMap(\.event).last?.event.body
    guard case .message(_, let text)? = message else { throw RPCError(code: 0, message: "no text") }
    #expect(text.hasPrefix("Reading the issue."))
}

@Test func jsonlAgentStreamsEventsAndTheLastResult() async throws {
    let agent = try FakeAgent(
        """
        echo '{"kind":"thinking","text":"looking"}'
        echo 'not json'
        echo '{"result":{"summary":"draft"}}'
        echo '{"kind":"message","role":"assistant","text":"done"}'
        echo '{"result":{"summary":"final"}}'
        """)
    let updates = try await execRun(agent, agent.profile(promptVia: .argument, parse: .jsonl))
    #expect(
        updates.compactMap(\.event).map(\.event.kind) == ["status", "thinking", "message"])
    #expect(try updates.compactMap(\.result).first?.decodedResult().summary == "final")
}

@Test func promptArgumentAndWorkdir() async throws {
    let agent = try FakeAgent(
        """
        last=""; for a in "$@"; do last="$a"; done
        case "$last" in *"Input (case):"*) ;; *) exit 7 ;; esac
        [ -f agent.sh ] || exit 8
        printf '```json\\n{"summary":"%s"}\\n```\\n' "$1"
        """)
    let updates = try await execRun(agent, agent.profile(promptVia: .argument, args: ["--flag"]))
    let result = try #require(updates.compactMap(\.result).first)
    #expect(result.status == .completed)
    #expect(try result.decodedResult().summary == "--flag")
}

@Test func mcpConfigIsWrittenIntoWorkdir() async throws {
    let agent = try FakeAgent(
        """
        cat > /dev/null
        [ "$1" = "--mcp" ] || exit 5
        printf '```json\\n'; cat "$2"; printf '\\n```\\n'
        """)
    let profile = agent.profile(mcpConfig: .file, args: ["--mcp", "{mcpConfig}"])
    let updates = try await execRun(agent, profile)
    let result = try #require(updates.compactMap(\.result).first?.result)
    #expect(result["mcpServers"]?["tracker"]?["args"] == ["binding-proxy"])
    let config = agent.directory.appendingPathComponent(ExecAdapterServer.mcpConfigFileName)
    #expect(!FileManager.default.fileExists(atPath: config.path))
}

@Test(arguments: [
    ("echo no result here", "without a result"),
    ("printf '```json\\n{\"summary\":\"x\"}\\n```\\n'; exit 3", "exited with status 3"),
    ("printf '```json\\n{\"summary\":7}\\n```\\n'", "does not match resultSchema"),
])
func failingAgentsFailTheRun(_ body: String, _ needle: String) async throws {
    let agent = try FakeAgent("cat > /dev/null\n" + body)
    let schema: JSONValue = ["type": "object", "properties": ["summary": ["type": "string"]]]
    let updates = try await execRun(agent, agent.profile(), schema: schema)
    #expect(updates.compactMap(\.result).first?.status == .failed)
    let errors = updates.compactMap(\.event).compactMap { params -> String? in
        if case .error(let message) = params.event.body { return message }
        return nil
    }
    #expect(errors.contains { $0.contains(needle) }, "\(errors)")
}

@Test func stopTerminatesTheAgent() async throws {
    let agent = try FakeAgent("cat > /dev/null\nexec sleep 30")
    let (transport, endpoint) = InMemoryPipe.make()
    let server = ExecAdapterServer(
        profile: agent.profile(), environment: ["PATH": "/usr/bin:/bin"], endpoint: endpoint)
    Task { await server.serve() }
    let adapter = AdapterConnection(transport: transport, timeouts: Sample.fast)
    let session = try await adapter.start(agent.start()).session
    try await adapter.stop(RunStopParams(session: session, reason: .user))
    let updates = await collect(adapter, until: \.isResult)
    #expect(updates.compactMap(\.result).first?.status == .stopped)
    try await adapter.shutdown()
}

@Test func execBinaryPassesConformanceBasics() async throws {
    let agent = try FakeAgent("cat > /dev/null\nprintf '```json\\n{\"summary\":\"ok\"}\\n```\\n'")
    let profiles = agent.directory.appendingPathComponent("adapters.json")
    let book = AdapterProfiles(profiles: ["agent": agent.profile()])
    try JSONEncoder().encode(book).write(to: profiles)
    let command = AdapterCommand(
        executable: AdapterUnderTest.productsDirectory.appendingPathComponent("arya-exec-adapter")
            .path,
        arguments: ["--profile", "agent", "--profiles", profiles.path],
        environment: ["PATH": "/usr/bin:/bin"])
    let adapter = try AdapterUnderTest.launch(command, timeouts: Sample.fast)
    let hello = try await adapter.initialize(InitializeParams(client: Sample.client))
    #expect(hello.adapter.name == "exec")
    #expect(hello.capabilities.tools == .none)
    let session = try await adapter.start(agent.start()).session
    let busy = await code { try await adapter.start(agent.start()) }
    #expect(busy == RPCErrorCode.busy)
    let updates = await collect(adapter, until: \.isResult)
    #expect(updates.compactMap(\.result).first?.status == .completed)
    #expect(
        updates.compactMap(\.event).map(\.seq) == Array(1..<(updates.compactMap(\.event).count + 1))
    )
    _ = try await adapter.cost(SessionParams(session: session))
    try await adapter.shutdown()
    #expect(await adapter.waitForExit() == .exited(0))
}
