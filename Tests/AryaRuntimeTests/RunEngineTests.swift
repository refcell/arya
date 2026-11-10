import AryaAdapters
import AryaCore
import Testing

@testable import AryaRuntime

struct FakeFactory: AdapterFactory {
    var script: FakeScript
    var timeouts = ConnectionTimeouts(
        request: .seconds(5), stopGrace: .milliseconds(200), killGrace: .milliseconds(200),
        exitGrace: .milliseconds(200))

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        FakeAdapter(script: script, timeouts: timeouts)
    }
}

let triageResult: JSONValue = [
    "summary": "Labeled ISSUE-7 as a bug.",
    "decisions": [["id": "d1", "choice": "bug", "rationale": "Login timeouts are bugs."]],
    "actions": [
        ["id": "a1", "kind": "label", "binding": "tracker", "target": "tracker:ISSUE-7"],
        ["id": "a2", "kind": "comment", "binding": "tracker", "target": "tracker:ISSUE-7"],
    ],
]

let toolCall = FakeScript.Step.event(
    RunEvent(.toolCall(id: "t1", tool: "tracker.get", input: ["id": "ISSUE-7"])))

struct RunHarness {
    let sink: MemoryEventSink
    let executor = RecordingExecutor()
    let loop: RunEngine
    let lifecycle: StewardLifecycle

    let approvals: ApprovalQueue

    init(
        _ run: FakeScript.Run, timeouts: ConnectionTimeouts? = nil, stepMillis: Int64 = 1,
        secondsUnit: Duration = .seconds(1)
    ) {
        self.init(
            script: FakeScript(runs: [run]), timeouts: timeouts, stepMillis: stepMillis,
            secondsUnit: secondsUnit)
    }

    init(
        script: FakeScript, timeouts: ConnectionTimeouts? = nil, stepMillis: Int64 = 1,
        secondsUnit: Duration = .seconds(1), proxy: BindingProxyLaunch? = nil,
        workdirRoot: String = "scratch", sandbox: Bool = false
    ) {
        let ambient = Ambient.fixed(stepMillis: stepMillis)
        sink = MemoryEventSink(ambient: ambient)
        approvals = ApprovalQueue(sink: sink, ambient: ambient)
        let dispatcher = ActionDispatcher(sink: sink, approvals: approvals, executor: executor)
        var factory = FakeFactory(script: script)
        if let timeouts { factory.timeouts = timeouts }
        loop = RunEngine(
            sink: sink, ambient: ambient, adapters: factory, dispatcher: dispatcher,
            approvals: approvals, workdir: { "\(workdirRoot)/\($0.rawValue)" },
            questionPoll: .milliseconds(1), secondsUnit: secondsUnit, proxy: proxy,
            sandbox: sandbox)
        lifecycle = StewardLifecycle(sink: sink)
    }

    func start(_ mode: RunMode = .live, charter: Charter = triageCharter()) async throws
        -> RunOutcome
    {
        if try await lifecycle.book().records[charter.id] == nil {
            try await lifecycle.create(charter)
        }
        var request = RunRequest.manual(charter.id, text: "New issue: login page times out")
        request.mode = mode
        return try await loop.run(request)
    }

    func types() async throws -> [String] {
        try await sink.events(from: 1).map(\.type).filter { $0 != "run.adapter.event" }
    }

    func last(_ type: String) async throws -> RuntimeEvent? {
        try await sink.events(from: 1).last { $0.type == type }
    }
}

@Test func completedRunIsFullyOnTheLedger() async throws {
    let harness = RunHarness(
        FakeScript.Run(
            steps: [toolCall], result: triageResult,
            cost: CostResult(
                inputTokens: 10, outputTokens: 5, costMicros: 1234)))
    let outcome = try await harness.start()

    #expect(outcome.phase == .finished(.completed))
    #expect(outcome.disposals.map(\.verdict.disposition) == [.auto, .ask])
    #expect(
        try await harness.types() == [
            "steward.created", "run.started", "run.step.started", "run.decision",
            "action.proposed", "action.executed", "action.proposed", "approval.requested",
            "run.finished",
        ])
    let started = try #require(try await harness.last("run.started"))
    #expect(started.draft.actor == .localUser)
    #expect(started.payload.objectValue?["charterVersion"] == 1)
    #expect(started.payload.objectValue?["input"]?.objectValue?["kind"] == "manual")
    let instructions = started.payload.objectValue?["instructions"]?.stringValue ?? ""
    #expect(instructions.hasPrefix("You are Issue triage"))
    let finished = try #require(try await harness.last("run.finished"))
    #expect(finished.payload.objectValue?["cost"]?.objectValue?["costMicros"] == 1234)
    #expect(finished.payload.objectValue?["status"] == "completed")
    #expect(await harness.executor.requests.map(\.action.id) == ["a1"])
}

@Test func everyWireLineIsRecordedInOrder() async throws {
    let harness = RunHarness(FakeScript.Run(steps: [toolCall], result: triageResult))
    _ = try await harness.start()
    let wire = try await harness.sink.events(from: 1).filter { $0.type == "run.adapter.event" }
    let methods = wire.compactMap { $0.payload.objectValue?["message"]?.objectValue?["method"] }
    #expect(
        methods == [
            "initialize", "run/start", "run/event", "run/result", "run/cost", "shutdown",
        ])
    #expect(wire.first?.payload.objectValue?["direction"] == "sent")
    #expect(wire.allSatisfy { $0.draft.actor.kind == "adapter" })
}

@Test func crashBeforeResultFailsWithAdapterExited() async throws {
    let harness = RunHarness(FakeScript.Run(steps: [toolCall, .crash(exitCode: 3)]))
    let outcome = try await harness.start()
    #expect(outcome.phase == .failed(.adapterExited))
    #expect(try await harness.types().suffix(1) == ["run.failed"])
    let failed = try await harness.last("run.failed")
    #expect(failed?.payload.objectValue?["reason"] == "adapter_exited")
}

@Test func undecodableResultFailsWithInvalidResult() async throws {
    let harness = RunHarness(FakeScript.Run(result: ["decisions": "not a list"]))
    let outcome = try await harness.start()
    #expect(outcome.phase == .failed(.invalidResult))
    #expect(!(try await harness.types().contains("run.decision")))
}

@Test func failedStatusFailsWithAdapterFailed() async throws {
    let harness = RunHarness(FakeScript.Run(status: .failed, result: ["summary": "harness broke"]))
    #expect(try await harness.start().phase == .failed(.adapterFailed))
}

@Test func startErrorFailsWithoutStreaming() async throws {
    let harness = RunHarness(
        FakeScript.Run(startError: RPCError(code: -32004, message: "harness failure")))
    let outcome = try await harness.start()
    #expect(outcome.phase == .failed(.adapterFailed))
    #expect(try await harness.types() == ["steward.created", "run.started", "run.failed"])
}

@Test func silentAdapterTimesOut() async throws {
    let fast = ConnectionTimeouts(
        request: .seconds(5), idle: .milliseconds(150), stopGrace: .milliseconds(150),
        killGrace: .milliseconds(150), exitGrace: .milliseconds(150))
    let harness = RunHarness(FakeScript.Run(steps: [.hang], ignoreStop: true), timeouts: fast)
    let outcome = try await harness.start()
    #expect(outcome.phase == .failed(.timeout))
}

@Test func rehearsalRecordsDispositionsOnlyAndDetectsLeaks() async throws {
    let harness = RunHarness(FakeScript.Run(steps: [toolCall], result: triageResult))
    let outcome = try await harness.start(.rehearsal(CaseContext()))
    #expect(outcome.phase == .finished(.completed))
    #expect(outcome.leak)
    #expect(
        try await harness.types() == [
            "steward.created", "run.started", "run.step.started", "run.decision",
            "action.proposed", "action.proposed", "run.finished",
        ])
    #expect(await harness.executor.requests.isEmpty)
    let book = try RunBook(try await harness.sink.events(from: 1))
    #expect(book.records[outcome.run]?.rehearsal == false)
}

@Test func answeredToolCallIsNoLeak() async throws {
    let harness = RunHarness(FakeScript.Run(steps: [toolCall], result: triageResult))
    let context = CaseContext(toolResults: [
        RecordedToolResult(tool: "tracker.get", input: ["id": "ISSUE-7"], output: ["ok": true])
    ])
    #expect(try await harness.start(.rehearsal(context)).leak == false)
}

@Test func retiredStewardCannotRun() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    let charter = triageCharter()
    try await harness.lifecycle.create(charter)
    try await harness.lifecycle.retire(charter.id)
    await #expect(throws: RunError.stewardRetired(charter.id)) {
        try await harness.loop.run(.manual(charter.id, text: "x"))
    }
}

private let askRun = FakeScript.Run(
    steps: [.ask(question: "Assign to the backend team?", to: "person:alex")],
    result: triageResult)

/// The `answer` arya sent back for the first `host/ask`, or `.null`.
private func sentAnswer(_ harness: RunHarness) async throws -> JSONValue? {
    let wire = try await harness.sink.events(from: 1).filter { $0.type == "run.adapter.event" }
    let reply = wire.first {
        $0.payload.objectValue?["direction"] == "sent"
            && $0.payload.objectValue?["message"]?.objectValue?["result"]?.objectValue?["answer"]
                != nil
    }
    return reply?.payload.objectValue?["message"]?.objectValue?["result"]?.objectValue?["answer"]
}

/// Decides the first pending question as soon as it appears.
private func decideWhenAsked(
    _ harness: RunHarness, grant: Bool, note: String? = nil
) -> Task<Void, any Error> {
    Task {
        while true {
            if let question = try await harness.approvals.book().pending.first {
                let person = RuntimeActor.person("person:alex")
                if grant {
                    try await harness.approvals.grant(question.id, by: person, note: note)
                } else {
                    try await harness.approvals.deny(question.id, by: person)
                }
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@Test func hostAskWaitsForAPersonsAnswer() async throws {
    let harness = RunHarness(askRun)
    let decider = decideWhenAsked(harness, grant: true, note: "yes, backend")
    let outcome = try await harness.start()
    try await decider.value
    #expect(outcome.phase == .finished(.completed))
    #expect(try await sentAnswer(harness) == "yes, backend")
    let book = try await harness.approvals.book()
    let question = try #require(
        book.all.first { $0.subject == .question("Assign to the backend team?") })
    #expect(question.to == "person:alex")
    #expect(question.decidedBy == .person("person:alex"))
    #expect(question.run == outcome.run)
}

@Test func deniedQuestionAnswersNull() async throws {
    let harness = RunHarness(askRun)
    let decider = decideWhenAsked(harness, grant: false)
    _ = try await harness.start()
    try await decider.value
    #expect(try await sentAnswer(harness) == .null)
}

@Test func unansweredQuestionExpiresAtTheRunTimeout() async throws {
    var charter = triageCharter()
    charter.limits.timeoutSeconds = 1
    // Ambient time runs 100 ms per reading, so the question expires before the connection's
    // wall-clock idle timer (also 1 second) would stop the run.
    let harness = RunHarness(askRun, stepMillis: 100)
    let outcome = try await harness.start(charter: charter)
    #expect(outcome.phase == .finished(.completed))
    #expect(try await sentAnswer(harness) == .null)
    #expect(try await harness.approvals.book().all.first?.status == .expired)
}

@Test func rehearsalQuestionsAnswerNullWithoutAsking() async throws {
    let harness = RunHarness(askRun)
    _ = try await harness.start(.rehearsal(CaseContext()))
    #expect(try await sentAnswer(harness) == .null)
    #expect(try await harness.approvals.book().all.isEmpty)
}
