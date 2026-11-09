import AryaAdapters
import AryaCore
import Testing

@testable import AryaRuntime

private actor ScriptedUpstream: ToolUpstream {
    let reply: JSONValue
    private(set) var calls: [(tool: String, arguments: JSONValue)] = []
    private(set) var closed = false

    init(reply: JSONValue) { self.reply = reply }

    func listTools() async throws -> [JSONValue] { [] }

    func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
        calls.append((tool, arguments))
        return reply
    }

    func close() async { closed = true }
}

private let tracker = CharterBinding.mcp(
    "tracker", command: "tracker-mcp", read: ["get"], actions: ["label"])
private let alex: CharterBinding = {
    var binding = CharterBinding.person("alex", channel: "local")
    binding.actions = ["message"]
    return binding
}()

private func request(_ action: ProposedAction, _ binding: CharterBinding?) -> ExecutionRequest {
    ExecutionRequest(
        steward: StewardID(unchecked: "st_triage"), run: RunID(unchecked: "run_01"),
        action: action, binding: binding)
}

private let label = ProposedAction(
    id: "a1", kind: "label", binding: "tracker", target: "tracker:ISSUE-7",
    params: ["label": "bug"])

@Test func mcpActionsCallTheToolNamedByTheKind() async throws {
    let upstream = ScriptedUpstream(reply: BindingProxy.result(["ok": true], isError: false))
    let executor = BindingActionExecutor { _ in upstream }
    let outcome = await executor.execute(request(label, tracker))
    #expect(outcome == .succeeded(output: ["ok": true]))
    let calls = await upstream.calls
    #expect(calls.map(\.tool) == ["label"])
    #expect(calls.first?.arguments == ["label": "bug", "target": "tracker:ISSUE-7"])
    try await Task.sleep(for: .milliseconds(20))
    #expect(await upstream.closed)
}

@Test func toolErrorsFailWithTheirText() async throws {
    let upstream = ScriptedUpstream(
        reply: [
            "content": [["type": "text", "text": "label not found"]], "isError": true,
        ])
    let outcome = await BindingActionExecutor { _ in upstream }.execute(request(label, tracker))
    guard case .failed(let error, _) = outcome else {
        Issue.record("expected failure")
        return
    }
    #expect(error == "label not found")
}

@Test func personActionsLandInTheLocalInbox() async {
    let message = ProposedAction(
        id: "m1", kind: "message", binding: "alex", params: ["text": "ISSUE-7 is a bug"])
    let outcome = await BindingActionExecutor().execute(request(message, alex))
    #expect(
        outcome
            == .succeeded(
                output: [
                    "inbox": "alex", "channel": "local", "params": ["text": "ISSUE-7 is a bug"],
                ]
            ))
}

@Test func disallowedKindsAndRoutinesWithoutARunnerFail() async {
    let executor = BindingActionExecutor { _ in ScriptedUpstream(reply: [:]) }
    let close = ProposedAction(id: "a2", kind: "close", binding: "tracker")
    #expect(
        await executor.execute(request(close, tracker))
            == .failed(error: "not_allowed:tracker.close", output: nil))
    let routine = ProposedAction(id: "r1", kind: "routine", params: ["name": "digest"])
    #expect(
        await executor.execute(request(routine, nil))
            == .failed(error: "no routine runner", output: nil))
    #expect(
        await executor.execute(request(label, nil)) == .failed(error: "no_binding", output: nil))
}

@Test func routinesGoToTheRoutineRunner() async {
    let runner = RecordingExecutor()
    let executor = BindingActionExecutor(routines: runner)
    let routine = ProposedAction(id: "r1", kind: "routine", params: ["name": "digest"])
    _ = await executor.execute(request(routine, nil))
    #expect(await runner.requests.map(\.action.id) == ["r1"])
}

@Test func connectFailuresAreOutcomes() async {
    struct Down: Error {}
    let outcome = await BindingActionExecutor { _ in throw Down() }.execute(request(label, tracker))
    guard case .failed(let error, nil) = outcome else {
        Issue.record("expected failure")
        return
    }
    #expect(error.hasPrefix("connect:"))
}
