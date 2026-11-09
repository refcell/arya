import AryaAdapters
import AryaCore
import AryaRuntime
import Testing

@testable import AryaEval

private struct FakeAdapters: AdapterFactory {
    var script: FakeScript

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        FakeAdapter(
            script: script,
            timeouts: ConnectionTimeouts(
                request: .seconds(5), stopGrace: .milliseconds(200),
                killGrace: .milliseconds(200), exitGrace: .milliseconds(200)))
    }
}

private let steward = StewardID(unchecked: "st_inbox")

private func inboxCharter(labelDecision: PolicyDecision = .auto) -> Charter {
    Charter(
        id: steward, name: "Inbox triage",
        outcome: "Every new message is labeled and routed within one hour.",
        metric: Metric(name: "routed_within_1h", unit: "ratio", direction: .up),
        bindings: [
            .mcp("inbox", command: "inbox-mcp", read: ["get"], actions: ["label", "route"])
        ],
        policy: Policy(rules: [Policy.Rule(action: "label", decision: labelDecision)]),
        adapter: "fake")
}

private let script = FakeScript(runs: [
    FakeScript.Run(
        input: "New message MSG-1",
        steps: [.event(RunEvent(.toolCall(id: "t1", tool: "inbox.get", input: ["id": "MSG-1"])))],
        result: [
            "summary": "Labeled MSG-1 as billing and asked to route it.",
            "decisions": [["id": "d1", "choice": "billing"]],
            "actions": [
                ["id": "a1", "kind": "label", "binding": "inbox", "target": "inbox:MSG-1"],
                ["id": "a2", "kind": "route", "binding": "inbox", "target": "inbox:MSG-1"],
            ],
        ])
])

/// Records one live manual run and returns the sink and its run id.
private func recordRun() async throws -> (MemoryEventSink, RunID) {
    let ambient = Ambient.fixed(stepMillis: 7, seed: 42)
    let sink = MemoryEventSink(ambient: ambient)
    try await StewardLifecycle(sink: sink).create(inboxCharter())
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let executor = RecordingExecutor(outcomes: ["label": .succeeded(output: ["labeled": true])])
    let engine = RunEngine(
        sink: sink, ambient: ambient, adapters: FakeAdapters(script: script),
        dispatcher: ActionDispatcher(sink: sink, approvals: approvals, executor: executor),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    let outcome = try await engine.run(.manual(steward, text: "New message MSG-1"))
    return (sink, outcome.run)
}

@Test func replayOfALiveRunHasNoDivergence() async throws {
    let (sink, run) = try await recordRun()
    let types = try await sink.events(from: 1).filter { $0.draft.run == run }.map(\.type)
    #expect(types.contains("action.executed"))
    #expect(types.contains("approval.requested"))

    let report = try await RunReplayer(sink: sink).replay(run: run)
    #expect(report.passed)
    #expect(report.comparedEvents > 4)
    #expect(report.run == run)
}

@Test func replayIgnoresEventsAfterTheRun() async throws {
    let (sink, run) = try await recordRun()
    try await StewardLifecycle(sink: sink).updateCharter(inboxCharter(labelDecision: .deny))
    #expect(try await RunReplayer(sink: sink).replay(run: run).passed)
}

@Test func replayCatchesUnrecordedState() async throws {
    let (sink, run) = try await recordRun()
    var replayer = RunReplayer(sink: sink)
    // A runtime bug that reads a charter from outside the ledger: the label rule changed.
    replayer.drift = { prefix in
        prefix.map { event in
            guard event.type == "steward.created" else { return event }
            var event = event
            var payload = event.draft.payload.objectValue ?? [:]
            payload["charter"] = try? CanonicalJSON.jsonValue(inboxCharter(labelDecision: .ask))
            event.draft.payload = .object(payload)
            return event
        }
    }
    let report = try await replayer.replay(run: run)
    let divergence = try #require(report.divergence)
    #expect(!report.passed)
    #expect(divergence.recorded != divergence.replayed)
    #expect(divergence.recorded?.type == "action.executed" || divergence.path.hasPrefix("payload"))
}

@Test func unknownRunIsReported() async throws {
    let sink = MemoryEventSink(ambient: .fixed())
    let run = RunID(unchecked: "run_missing")
    await #expect(throws: EvalError.unknownRun(run)) {
        try await RunReplayer(sink: sink).replay(run: run)
    }
}

@Test func canonicalizerRenamesIdsAndTimesByFirstAppearance() {
    var names: [String: String] = [:]
    let value: JSONValue = [
        "a": "ap_01JC3F0000000000000000000A", "b": ["ap_01JC3F0000000000000000000A", "x_y"],
        "c": "2026-01-01T00:00:00.000Z", "d": "st_triage",
    ]
    let renamed = Canonicalizer.rename(value, &names)
    #expect(renamed["a"] == "<id:1>")
    #expect(renamed["b"] == ["<id:1>", "x_y"])
    #expect(renamed["c"] == "<time:1>")
    #expect(renamed["d"] == "st_triage")
}
