import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// Runs `command` under the example `shell` profile and returns its updates up to the result.
private func shellRun(_ command: String) async throws -> [AdapterUpdate] {
    let workdir = try FakeAgent("")
    let (transport, endpoint) = InMemoryPipe.make()
    let server = ExecAdapterServer(
        profile: AdapterProfiles.shell, environment: ["PATH": "/usr/bin:/bin"],
        endpoint: endpoint)
    Task { await server.serve() }
    let adapter = AdapterConnection(transport: transport, timeouts: Sample.timeouts)
    _ = try await adapter.initialize(InitializeParams(client: Sample.client))
    _ = try await adapter.start(workdir.start(command))
    let updates = await collect(adapter, until: \.isResult)
    try await adapter.shutdown()
    return updates
}

/// A routine's command shows as one `shell` call whose stdout and stderr stream line by line,
/// and a printed `{"result": …}` line is the run's result.
@Test func commandProfileStreamsOutputLineByLine() async throws {
    let updates = try await shellRun(
        #"""
        printf 'one\ntwo\n'; echo careful >&2
        printf '{"result":{"summary":"two lines","decisions":[],"actions":[]}}\n'
        """#)
    let events = updates.compactMap(\.event).map(\.event)
    guard case .toolCall("command", "shell", let input)? = events.dropFirst().first?.body else {
        Issue.record("no shell call first: \(events)")
        return
    }
    #expect(input["command"]?.stringValue?.contains("printf 'one") == true)
    let chunks = events.compactMap(\.outputChunk)
    #expect(chunks.filter { $0.stream == "stdout" }.prefix(2).map(\.text) == ["one\n", "two\n"])
    #expect(chunks.contains { $0.stream == "stderr" && $0.text == "careful\n" })
    guard case .toolResult("command", let output, false)? = events.last?.body else {
        Issue.record("no clean result last: \(events)")
        return
    }
    #expect(output["exitCode"] == 0)
    let result = try #require(updates.compactMap(\.result).first)
    #expect(result.status == .completed)
    #expect(try result.decodedResult().summary == "two lines")
}

/// A failing command fails the run, with its stderr shown and the exit in the summary.
@Test func failingCommandFailsTheRunWithItsOutput() async throws {
    let updates = try await shellRun("echo 'no such queue' >&2; exit 3")
    let events = updates.compactMap(\.event).map(\.event)
    #expect(events.compactMap(\.outputChunk).map(\.text) == ["no such queue\n"])
    #expect(
        events.contains {
            if case .toolResult("command", let output, true) = $0.body {
                return output["exitCode"] == 3
            }
            return false
        })
    let result = try #require(updates.compactMap(\.result).first)
    #expect(result.status == .failed)
    #expect(try result.decodedResult().summary.contains("3"))
}

/// With partial messages on, the reply streams as a `compose` step whose output pieces add
/// up to the final message, before that message and the result arrive.
@Test func partialMessagesStreamAsAComposeStep() async throws {
    let fixture = Fixtures.url("stream-json-partial.jsonl").path
    let agent = try FakeAgent("cat > /dev/null\ncat '\(fixture)'")
    let updates = try await execRun(agent, agent.profile(parse: .streamJSON))
    let events = updates.compactMap(\.event).map(\.event)
    let kinds = events.map(\.kind)
    #expect(
        kinds == [
            "status", "tool_call", "tool_output", "tool_output", "tool_output", "tool_output",
            "tool_result", "message",
        ])
    guard case .message(_, let text)? = events.last?.body else {
        Issue.record("no message last")
        return
    }
    #expect(events.compactMap(\.outputChunk).map(\.text).joined() == text)
    #expect(events.compactMap(\.outputChunk).allSatisfy { $0.id == "msg_01:0" })
    let result = try #require(updates.compactMap(\.result).first)
    #expect(result.status == .completed)
    #expect(try result.decodedResult().summary == "Labeled ISSUE-1.")
}

/// Opt-in, never in CI: `ARYA_LIVE_HARNESS=<example profile>` (such as `shell`, or a
/// command-line agent profile installed on `PATH` and signed in) runs one real run end to
/// end. To refresh a transcript fixture, run the agent's command by hand and save its stdout.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARYA_LIVE_HARNESS"] != nil))
func liveHarnessRunsEndToEnd() async throws {
    let environment = ProcessInfo.processInfo.environment
    let name = try #require(environment["ARYA_LIVE_HARNESS"])
    let profile = try AdapterProfiles.examples.profile(name)
    let workdir = try FakeAgent("")
    let (transport, endpoint) = InMemoryPipe.make()
    let server = ExecAdapterServer(
        profile: profile, environment: environment, endpoint: endpoint)
    Task { await server.serve() }
    let adapter = AdapterConnection(
        transport: transport, timeouts: .standard)
    _ = try await adapter.initialize(InitializeParams(client: Sample.client))
    let input =
        profile.parse == .command
        ? #"printf '{"result":{"summary":"ok","decisions":[],"actions":[]}}\n'"#
        : #"Reply with exactly {"summary":"ok","decisions":[],"actions":[]} as the result."#
    _ = try await adapter.start(workdir.start(input))
    let updates = await collect(adapter, until: \.isResult)
    try await adapter.shutdown()
    let result = try #require(updates.compactMap(\.result).first)
    #expect(result.status == .completed, "\(updates.compactMap(\.event).map(\.event))")
    #expect(!updates.compactMap(\.event).isEmpty)
}
