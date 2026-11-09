import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

@Test func stderrIsCaptured() async throws {
    let stderr = StderrBuffer()
    let command = AdapterCommand(
        executable: AdapterUnderTest.fakeAdapterPath, environment: ["PATH": "/usr/bin:/bin"])
    let adapter = try AdapterUnderTest.launch(command, stderr: stderr)
    #expect(await adapter.waitForExit() == .exited(2))
    #expect(String(decoding: stderr.contents, as: UTF8.self).contains("usage"))
}

@Test func processCrashIsReportedAsExit() async throws {
    let adapter = try AdapterUnderTest.launch(AdapterUnderTest.fake(script: "crash-script.json"))
    _ = try await adapter.start(Sample.start("x"))
    let updates = await collect(adapter)
    #expect(updates.compactMap(\.event).count == 1)
    #expect(updates.compactMap(\.result).isEmpty)
    #expect(updates.last?.exit == .exited(3))
}

@Test func commandNamesAreLookedUpOnPath() async throws {
    let command = AdapterCommand(
        executable: "sh", arguments: ["-c", "exit 4"], environment: ["PATH": "/usr/bin:/bin"])
    let adapter = try AdapterUnderTest.launch(command)
    #expect(await adapter.waitForExit() == .exited(4))
}

@Test func missingExecutableFailsToLaunch() {
    let command = AdapterCommand(executable: "/nonexistent/adapter")
    #expect(throws: AdapterError.self) { try AdapterUnderTest.launch(command) }
}

@Test func adapterIgnoringSIGTERMIsKilled() async throws {
    // The shell ignores SIGTERM and its `sleep` child keeps stdout open after the kill.
    let command = AdapterCommand(
        executable: "/bin/sh",
        arguments: ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"],
        environment: ["PATH": "/usr/bin:/bin"])
    let transport = try ProcessTransport.launch(command)
    var inputs = transport.input.makeAsyncIterator()
    // Terminate only once the trap is in place, however slow the machine is.
    #expect(await inputs.next() == .line(Data("ready".utf8)))
    await transport.terminate(grace: .milliseconds(200))
    var last: TransportInput?
    while let input = await inputs.next() { last = input }
    #expect(last == .ended(.signaled(SIGKILL)))
}

@Test func runOverAProcessMatchesTheScript() async throws {
    let adapter = try AdapterUnderTest.launch(
        AdapterUnderTest.fake(script: "conformance-script.json"))
    _ = try await adapter.initialize(InitializeParams(client: Sample.client))
    _ = try await adapter.start(Sample.start("x"))
    let updates = await collect(adapter, until: \.isResult)
    #expect(
        updates.compactMap(\.event).map(\.event.kind) == [
            "status", "message", "tool_call", "tool_result",
        ])
    #expect(try updates.compactMap(\.result).first?.decodedResult().summary == "Nothing to do.")
    try await adapter.shutdown()
    #expect(await adapter.waitForExit() == .exited(0))
}

@Test func adapterThatStopsReadingStillTimesOut() async throws {
    // The adapter never reads stdin, so a large request fills the pipe; the request must still
    // time out, and shutdown must still terminate the adapter.
    let command = AdapterCommand(
        executable: "sh", arguments: ["-c", "exec sleep 30"],
        environment: ["PATH": "/usr/bin:/bin"])
    var timeouts = Sample.fast
    timeouts.request = .milliseconds(300)
    let adapter = try AdapterUnderTest.launch(command, timeouts: timeouts)
    let big: JSONValue = ["blob": .string(String(repeating: "x", count: 1 << 20))]
    await #expect(throws: AdapterError.requestTimedOut(method: "run/huge")) {
        try await adapter.request("run/huge", params: big)
    }
    try? await adapter.shutdown()
    #expect(await adapter.waitForExit() != .exited(0))
}
