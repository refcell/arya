import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

@Test func wrapLaunchesTheCommandUnderSandboxExec() {
    let command = AdapterCommand(
        executable: "agent", arguments: ["-p"], environment: ["PATH": "/usr/bin:/bin"],
        workingDirectory: "/work")
    let request = SandboxRequest(profile: "(version 1)", params: ["WORKDIR": "/work", "A": "1"])
    let wrapped = OSSandbox.wrap(command, in: request, sandboxExec: "/sbx")
    #expect(wrapped.executable == "/sbx")
    #expect(
        wrapped.arguments == [
            "-p", "(version 1)", "-D", "A=1", "-D", "WORKDIR=/work", "/usr/bin/env", "agent", "-p",
        ])
    #expect(wrapped.environment == command.environment)
    #expect(wrapped.workingDirectory == "/work")
    let absolute = AdapterCommand(executable: "/bin/agent")
    #expect(OSSandbox.wrap(absolute, in: request).arguments.suffix(1) == ["/bin/agent"])
}

@Test func confiningProfileNamesItsWritablePlaces() {
    let open = OSSandbox.profileConfiningWrites(extraWritablePaths: ["/state/dir"])
    #expect(open.contains("(deny file-write*)"))
    #expect(open.contains("(subpath (param \"WORKDIR\"))"))
    #expect(open.contains("(subpath \"/state/dir\")"))
    #expect(!open.contains("network"))
    let closed = OSSandbox.profileConfiningWrites(network: .denied)
    #expect(closed.contains("(deny network-outbound (remote ip))"))
}

@Test func execWithoutSandboxExecRejectsASandboxedRun() async throws {
    let agent = try FakeAgent("cat > /dev/null")
    let (transport, endpoint) = InMemoryPipe.make()
    let server = ExecAdapterServer(
        profile: agent.profile(), environment: ["PATH": "/usr/bin:/bin"], endpoint: endpoint,
        sandboxExec: nil)
    Task { await server.serve() }
    let adapter = AdapterConnection(transport: transport, timeouts: Sample.timeouts)
    let hello = try await adapter.initialize(InitializeParams(client: Sample.client))
    #expect(hello.capabilities.sandbox == .none)
    var start = agent.start()
    start.sandbox = OSSandbox.confiningWrites(to: agent.directory.path)
    #expect(await code { try await adapter.start(start) } == RPCErrorCode.capabilityNotSupported)
    try await adapter.shutdown()
}

@Test func fakeWithoutOSSandboxRejectsASandboxedRun() async throws {
    let adapter = FakeAdapter(script: Sample.script, timeouts: Sample.timeouts)
    var start = Sample.start("x")
    start.sandbox = SandboxRequest(profile: "(version 1)")
    #expect(await code { try await adapter.start(start) } == RPCErrorCode.capabilityNotSupported)
}

@Test(.enabled(if: OSSandbox.isAvailable))
func sandboxedAgentWritesOnlyInsideItsWorkdir() async throws {
    let agent = try FakeAgent(
        """
        cat > /dev/null
        echo inside > inside.txt
        echo temp > "$TMPDIR/temp.txt"
        echo outside > ../outside-$$.txt 2>/dev/null && wrote=yes || wrote=no
        printf '```json\\n{"summary":"%s"}\\n```\\n' "$wrote"
        """)
    // The workdir is a subdirectory, so its parent is writable without the sandbox.
    let workdir = agent.directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    let (transport, endpoint) = InMemoryPipe.make()
    let server = ExecAdapterServer(
        profile: agent.profile(), environment: ["PATH": "/usr/bin:/bin"], endpoint: endpoint)
    Task { await server.serve() }
    let adapter = AdapterConnection(transport: transport, timeouts: Sample.timeouts)
    let hello = try await adapter.initialize(InitializeParams(client: Sample.client))
    #expect(hello.capabilities.sandbox == .os)
    var start = agent.start()
    start.workdir = workdir.path
    start.sandbox = OSSandbox.confiningWrites(to: workdir.path)
    _ = try await adapter.start(start)
    let updates = await collect(adapter, until: \.isResult)
    try await adapter.shutdown()
    let result = try #require(updates.compactMap(\.result).first)
    #expect(result.status == .completed, "\(updates)")
    #expect(try result.decodedResult().summary == "no")
    let inside = workdir.appendingPathComponent("inside.txt")
    #expect(FileManager.default.fileExists(atPath: inside.path))
    let temp = workdir.appendingPathComponent(".tmp/temp.txt")
    #expect(FileManager.default.fileExists(atPath: temp.path))
}
