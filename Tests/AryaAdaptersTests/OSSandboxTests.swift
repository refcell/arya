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

/// Runs `body` as a sandboxed agent (network denied) in a `work` subdirectory and returns the
/// updates up to the result.
func sandboxedRun(_ body: String) async throws -> (FakeAgent, [AdapterUpdate]) {
    let agent = try FakeAgent(body)
    let workdir = agent.directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    let (transport, endpoint) = InMemoryPipe.make()
    let server = ExecAdapterServer(
        profile: agent.profile(), environment: ["PATH": "/usr/bin:/bin"], endpoint: endpoint)
    Task { await server.serve() }
    let adapter = AdapterConnection(transport: transport, timeouts: Sample.timeouts)
    _ = try await adapter.initialize(InitializeParams(client: Sample.client))
    var start = agent.start()
    start.workdir = workdir.path
    start.sandbox = OSSandbox.confiningWrites(to: workdir.path, network: .denied)
    _ = try await adapter.start(start)
    let updates = await collect(adapter, until: \.isResult)
    try await adapter.shutdown()
    return (agent, updates)
}

func errorMessages(_ updates: [AdapterUpdate]) -> [String] {
    updates.compactMap(\.event).compactMap { params in
        if case .error(let message) = params.event.body { return message }
        return nil
    }
}

@Test(.enabled(if: OSSandbox.isAvailable))
func sandboxBlocksOutsideWritesAndNetworkAndSaysSoOnce() async throws {
    let (agent, updates) = try await sandboxedRun(
        """
        cat > /dev/null
        (echo outside > ../outside.txt) && wrote=yes || wrote=no
        /usr/bin/nc -zv -w 2 127.0.0.1 9 2> nc.err
        if grep -q "not permitted" nc.err; then net=denied; else net=allowed; fi
        cat nc.err >&2
        printf '```json\\n{"summary":"%s %s"}\\n```\\n' "$wrote" "$net"
        """)
    let result = try #require(updates.compactMap(\.result).first)
    #expect(try result.decodedResult().summary == "no denied", "\(updates)")
    let outside = agent.directory.appendingPathComponent("outside.txt")
    #expect(!FileManager.default.fileExists(atPath: outside.path))
    let errors = errorMessages(updates)
    #expect(errors.count == 1, "\(errors)")
    let report = try #require(errors.first)
    #expect(report.hasPrefix("The sandbox blocked the agent from writing outside its workdir"))
    #expect(report.contains("Operation not permitted"))
    #expect(report.hasSuffix(").") && !report.contains("\n"))
}

@Test(.enabled(if: OSSandbox.isAvailable))
func cleanSandboxedRunReportsNoDenial() async throws {
    let (_, updates) = try await sandboxedRun(
        """
        cat > /dev/null
        echo fine > inside.txt
        printf '```json\\n{"summary":"ok"}\\n```\\n'
        """)
    #expect(updates.compactMap(\.result).first?.status == .completed)
    #expect(errorMessages(updates).isEmpty)
}

@Test func denialWatcherFindsTheFirstDeniedLine() {
    let forwarded = StderrBuffer()
    let watcher = SandboxDenialWatcher(forwardingTo: forwarded)
    watcher.append(Data("warming up\nsh: ../a: Operation not ".utf8))
    #expect(watcher.report == nil)
    watcher.append(Data("permitted\nsecond: Operation not permitted\n".utf8))
    #expect(watcher.firstDenial == "sh: ../a: Operation not permitted")
    #expect(forwarded.contents.count > 0)
    let partial = SandboxDenialWatcher(forwardingTo: StderrBuffer())
    partial.append(Data("tail without newline: operation not permitted".utf8))
    #expect(partial.firstDenial == "tail without newline: operation not permitted")
}
