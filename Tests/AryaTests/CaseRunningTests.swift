import AryaAdapters
import AryaCore
import AryaEval
import AryaRuntime
import Testing

@testable import Arya

struct ScriptedFactory: AdapterFactory {
    var script: FakeScript

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        FakeAdapter(
            script: script,
            timeouts: ConnectionTimeouts(
                request: .seconds(5), stopGrace: .milliseconds(200),
                killGrace: .milliseconds(200), exitGrace: .milliseconds(200)))
    }
}

func inboxCharter() -> Charter {
    Charter(
        id: StewardID(unchecked: "st_inbox"), name: "Inbox triage",
        outcome: "Every new message is labeled and routed within one hour.",
        metric: Metric(name: "routed_within_1h", unit: "ratio", direction: .up),
        bindings: [
            .mcp("inbox", command: "inbox-mcp", read: ["get"], actions: ["label", "route"])
        ],
        policy: Policy(rules: [Policy.Rule(action: "label", decision: .auto)]),
        adapter: "fake")
}

func inboxResult(_ choice: String, _ message: String) -> JSONValue {
    [
        "summary": .string("Labeled \(message) as \(choice)."),
        "decisions": [["id": "d1", "choice": .string(choice)]],
        "actions": [
            [
                "id": "a1", "kind": "label", "binding": "inbox",
                "target": .string("inbox:\(message)"),
            ]
        ],
    ]
}

func inboxCase(_ id: String, _ message: String, _ choice: String, read: Bool = true) -> Case {
    let reads =
        read
        ? [RecordedToolResult(tool: "inbox.get", input: ["id": .string(message)], output: [:])]
        : []
    return Case(
        id: CaseID(rawValue: id)!, input: CaseInput(text: "New message \(message)"),
        context: CaseContext(toolResults: reads),
        expected: [
            "decisions": [["choice": .string(choice)]],
            "actions": [["kind": "label", "target": .string("inbox:\(message)")]],
        ])
}

func inboxRun(_ message: String, _ choice: String) -> FakeScript.Run {
    FakeScript.Run(
        input: "New message \(message)",
        steps: [
            .event(
                RunEvent(.toolCall(id: "t1", tool: "inbox.get", input: ["id": .string(message)])))
        ],
        result: inboxResult(choice, message))
}

struct CaseHarness {
    let ambient = Ambient.fixed(stepMillis: 1)
    let sink: MemoryEventSink
    let executor = RecordingExecutor()
    let loop: RunEngine

    init(_ runs: [FakeScript.Run]) {
        sink = MemoryEventSink(ambient: ambient)
        let approvals = ApprovalQueue(sink: sink, ambient: ambient)
        loop = RunEngine(
            sink: sink, ambient: ambient, adapters: ScriptedFactory(script: FakeScript(runs: runs)),
            dispatcher: ActionDispatcher(sink: sink, approvals: approvals, executor: executor),
            approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    }

    func rehearser(_ book: Casebook) -> CasebookRehearser {
        CasebookRehearser(
            runner: RuntimeCaseRunner(loop: loop, sink: sink), casebooks: OneCasebook(book: book),
            sink: sink, ambient: ambient,
            scorer: ExactScorer(fields: ["decisions.choice", "actions.kind", "actions.target"]))
    }
}

struct OneCasebook: CasebookSource {
    var book: Casebook
    func casebook(version: String) async throws -> Casebook { book }
}

@Test func rehearsalRunsEachCaseThroughTheRunLoop() async throws {
    let harness = CaseHarness([inboxRun("MSG-1", "billing"), inboxRun("MSG-2", "billing")])
    let charter = inboxCharter()
    try await StewardLifecycle(sink: harness.sink).create(charter)
    let book = try Casebook(
        name: "inbox",
        cases: [inboxCase("case-1", "MSG-1", "billing"), inboxCase("case-2", "MSG-2", "bug")])
    let request = RehearsalRequest(
        steward: charter.id, charterVersion: 1, casebookVersion: book.version)

    let result = try await harness.rehearser(book).rehearse(request, charter: charter)

    #expect(result.outcomes.map(\.caseID.rawValue) == ["case-1", "case-2"])
    #expect(result.outcomes.map { $0.samples[0].passed } == [true, false])
    #expect(result.outcomes.allSatisfy { !$0.leak })
    let events = try await harness.sink.events(from: 1)
    let starts = events.filter { $0.type == RunEventType.started }
    #expect(starts.count == 2)
    for start in starts {
        #expect(start.payload["input"]?["kind"] == "case")
        #expect(start.payload["rehearsal"]?.stringValue?.hasPrefix("reh_") == true)
        #expect(start.payload["sample"] == 1)
        #expect(start.payload["charterVersion"] == 1)
        #expect(start.draft.actor == .system)
    }
    #expect(!events.contains { $0.type == ActionEventType.executed })
    #expect(await harness.executor.requests.isEmpty)
}

@Test func unansweredToolReadMarksTheCaseAsLeaking() async throws {
    let harness = CaseHarness([inboxRun("MSG-1", "billing")])
    let charter = inboxCharter()
    try await StewardLifecycle(sink: harness.sink).create(charter)
    let book = try Casebook(
        name: "inbox", cases: [inboxCase("case-1", "MSG-1", "billing", read: false)])
    let request = RehearsalRequest(
        steward: charter.id, charterVersion: 1, casebookVersion: book.version)

    let result = try await harness.rehearser(book).rehearse(request, charter: charter)

    #expect(result.outcomes[0].leak)
    #expect(!result.outcomes[0].samples[0].passed)
}

@Test func candidateCharterRunsAsVersionZero() async throws {
    let harness = CaseHarness([inboxRun("MSG-1", "billing")])
    let charter = inboxCharter()
    try await StewardLifecycle(sink: harness.sink).create(charter)
    var candidate = charter
    candidate.outcome = "Every new message is routed within ten minutes."
    let book = try Casebook(name: "inbox", cases: [inboxCase("case-1", "MSG-1", "billing")])
    let request = RehearsalRequest(
        steward: charter.id, charterVersion: 2, casebookVersion: book.version)

    let result = try await harness.rehearser(book).rehearse(request, charter: candidate)

    let start = try await harness.sink.events(from: 1).last { $0.type == RunEventType.started }
    #expect(start?.payload["charterVersion"] == 0)
    #expect(result.outcomes[0].samples[0].passed)
}

@Test func failedRunScoresAgainstAnEmptyResult() throws {
    #expect(try RuntimeCaseRunner.shape(nil) == .object([:]))
}
