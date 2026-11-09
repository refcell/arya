import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private let parentText = "New issue: login page times out"

private let delegating: JSONValue = [
    "summary": "Split the triage.",
    "delegations": [
        ["id": "d1", "title": "Check logs", "input": "check logs"],
        ["id": "d2", "title": "Check history", "input": "check history"],
    ],
]

private func childResult(_ tag: String) -> JSONValue {
    [
        "summary": .string("\(tag) done"),
        "decisions": [["id": .string("c-\(tag)"), "choice": "bug", "rationale": "seen before"]],
        "actions": [["id": .string("x-\(tag)"), "kind": "label", "binding": "tracker"]],
    ]
}

private let joinResult: JSONValue = [
    "summary": "Joined.",
    "actions": [["id": "j1", "kind": "comment", "binding": "tracker"]],
]

private func crewScript(childSteps: [FakeScript.Step] = []) -> FakeScript {
    FakeScript(runs: [
        FakeScript.Run(input: parentText, result: delegating),
        FakeScript.Run(input: "check logs", steps: childSteps, result: childResult("logs")),
        FakeScript.Run(input: "check history", steps: childSteps, result: childResult("history")),
        FakeScript.Run(result: joinResult),
    ])
}

private func crewCharter(maxParallel: Int) -> Charter {
    var charter = triageCharter()
    charter.crew = Crew(maxParallel: maxParallel)
    return charter
}

@Test func delegationsRunAsChildrenThenOneJoin() async throws {
    let harness = RunHarness(script: crewScript())
    let outcome = try await harness.start(charter: crewCharter(maxParallel: 2))
    let crew = try #require(outcome.crew)
    #expect(crew.children.map(\.result?.summary) == ["logs done", "history done"])
    #expect(crew.join.result?.summary == "Joined.")

    let book = try RunBook(try await harness.sink.events(from: 1))
    let runs = book.all
    #expect(runs.count == 4)
    #expect(runs.filter { $0.parent == outcome.run }.count == 3)
    let join = try #require(book.records[crew.join.run])
    #expect(join.trigger == "join")

    // The join input carries each child's summary, decisions, and proposals, in order.
    let input = try CanonicalJSON.decode(JSONValue.self, from: Data(join.input.utf8))
    let reports = try #require(input["children"]?.arrayValue)
    #expect(reports.map { $0["delegation"] } == ["d1", "d2"])
    #expect(reports[0]["status"] == "completed")
    #expect(reports[0]["actions"]?[0]?["id"] == "x-logs")
    #expect(reports[1]["decisions"]?[0]?["choice"] == "bug")

    // Children only propose; the join's action goes through policy (default: ask).
    #expect(crew.children.allSatisfy { $0.disposals.allSatisfy { $0.approval == nil } })
    let pending = try await harness.approvals.book().pending
    #expect(pending.count == 1)
    #expect(crew.join.disposals.first?.approval == pending.first?.id)
    #expect(await harness.executor.requests.isEmpty)
}

/// Waits until exactly `count` questions are pending (each blocks one live child), then checks
/// that no more show up, and answers them.
private func answer(_ count: Int, in harness: RunHarness) async throws {
    var pending: [ApprovalRecord] = []
    for _ in 0..<2000 where pending.count < count {
        pending = try await harness.approvals.book().pending
        try await Task.sleep(for: .milliseconds(2))
    }
    try await Task.sleep(for: .milliseconds(50))
    pending = try await harness.approvals.book().pending
    #expect(pending.count == count)
    for record in pending { _ = try await harness.approvals.grant(record.id, by: .localUser) }
}

@Test func crewRespectsMaxParallel() async throws {
    // Each child asks a question and waits, so pending questions = children running at once.
    for width in [1, 2] {
        let harness = RunHarness(
            script: crewScript(childSteps: [.ask(question: "Which log?", to: nil)]))
        let run = Task { try await harness.start(charter: crewCharter(maxParallel: width)) }
        if width == 1 {
            try await answer(1, in: harness)
            try await answer(1, in: harness)
        } else {
            try await answer(2, in: harness)
        }
        let outcome = try await run.value
        #expect(try #require(outcome.crew).children.count == 2)
    }
}

@Test func childrenAndJoinsNeverFanOut() async throws {
    // Every run delegates; only the top-level run's delegations become children.
    let script = FakeScript(runs: [FakeScript.Run(result: delegating)])
    let harness = RunHarness(script: script)
    let outcome = try await harness.start(charter: crewCharter(maxParallel: 2))
    let crew = try #require(outcome.crew)
    #expect(crew.children.allSatisfy { $0.crew == nil })
    #expect(crew.join.crew == nil)
    #expect(try RunBook(try await harness.sink.events(from: 1)).all.count == 4)
}

@Test func rehearsalRunsDoNotFanOut() async throws {
    let harness = RunHarness(script: crewScript())
    let outcome = try await harness.start(
        .rehearsal(CaseContext()), charter: crewCharter(maxParallel: 2))
    #expect(outcome.crew == nil)
}

/// A factory that records which adapter profile each run asked for.
private actor AdapterLog {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

private struct LoggingFactory: AdapterFactory {
    let inner: FakeFactory
    let log: AdapterLog
    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        await log.add(charter.adapter)
        return try await inner.makeAdapter(for: charter, run: run)
    }
}

@Test func delegationsGetBoundedBudgetsAndAllowedAdapters() async throws {
    let parentResult: JSONValue = [
        "summary": "Split.",
        "delegations": [
            [
                "id": "d1", "title": "Logs", "input": "check logs", "adapter": "helper",
                "effort": "low", "limits": ["maxTurns": 5, "maxCostMicros": 99_000_000],
            ],
            ["id": "d2", "title": "Rogue", "input": "rogue", "adapter": "unlisted"],
            ["id": "d3", "title": "Loud", "input": "loud", "effort": "extreme"],
            ["id": "d4", "title": "History", "input": "check history", "effort": "high"],
        ],
    ]
    let script = FakeScript(runs: [
        FakeScript.Run(input: parentText, result: parentResult),
        FakeScript.Run(input: "check logs", result: childResult("logs")),
        FakeScript.Run(input: "check history", result: childResult("history")),
        FakeScript.Run(result: joinResult),
    ])
    let harness = RunHarness(script: script)
    let log = AdapterLog()
    let ambient = Ambient.fixed(stepMillis: 1)
    let engine = RunEngine(
        sink: harness.sink, ambient: ambient,
        adapters: LoggingFactory(inner: FakeFactory(script: script), log: log),
        dispatcher: ActionDispatcher(
            sink: harness.sink, approvals: harness.approvals, executor: harness.executor),
        approvals: harness.approvals, workdir: { "scratch/\($0.rawValue)" },
        questionPoll: .milliseconds(1))
    var charter = crewCharter(maxParallel: 1)
    charter.effort = .medium
    charter.crew.adapters = ["helper"]
    try await harness.lifecycle.create(charter)
    let outcome = try await engine.run(.manual(charter.id, text: parentText))
    let crew = try #require(outcome.crew)
    #expect(crew.children.count == 2)
    #expect(await log.names == ["fake", "helper", "fake", "fake"])

    let events = try await harness.sink.events(from: 1)
    let delegated = events.filter { $0.type == RunDelegated.type.rawValue }
    #expect(delegated.allSatisfy { $0.draft.run == outcome.run })
    #expect(delegated.allSatisfy { $0.draft.actor == .steward(charter.id) })
    let byID = Dictionary(
        uniqueKeysWithValues: delegated.map { ($0.payload["delegation"]?.stringValue ?? "", $0) })
    #expect(byID["d2"]?.payload["refused"] == "adapter_not_allowed:unlisted")
    #expect(byID["d3"]?.payload["refused"] == "unknown_effort:extreme")
    let logs = try #require(byID["d1"]?.payload)
    #expect(logs["adapter"] == "helper")
    #expect(logs["effort"] == "low")
    #expect(logs["limits"]?["maxTurns"] == 5)
    // Asking for more than the parent gets the parent's.
    #expect(logs["limits"]?["maxCostMicros"] == 2_000_000)
    #expect(byID["d4"]?.payload["effort"] == "medium")
    #expect(byID["d4"]?.payload["adapter"] == "fake")

    // Each child's run.started links to the parent and records what it ran with.
    let childID = try #require(logs["child"]?.stringValue)
    let started = try #require(
        events.first { $0.type == "run.started" && $0.draft.run?.rawValue == childID })
    #expect(started.payload["parent"]?.stringValue == outcome.run.rawValue)
    #expect(started.payload["adapter"] == "helper")
    #expect(started.payload["effort"] == "low")
    #expect(started.payload["limits"]?["maxTurns"] == 5)

    // The join hears about refusals too.
    let joinStarted = try #require(
        events.first { $0.type == "run.started" && $0.draft.run == crew.join.run })
    let input = joinStarted.payload["input"]?["text"]?.stringValue ?? ""
    #expect(input.contains("refused:adapter_not_allowed:unlisted"))
}

@Test func crewBudgetsNeverExceedTheCharter() {
    var charter = triageCharter()
    charter.effort = .low
    charter.limits = Limits(maxTurns: 10, timeoutSeconds: 60, maxCostMicros: 1000)
    let applied = CrewBudget(
        adapter: "elsewhere", effort: .high,
        limits: Limits(maxTurns: 0, timeoutSeconds: 600, maxCostMicros: 5)
    ).applied(to: charter)
    #expect(applied.adapter == charter.adapter)
    #expect(applied.effort == .low)
    #expect(applied.limits == Limits(maxTurns: 1, timeoutSeconds: 60, maxCostMicros: 5))
    #expect(applied.policy == charter.policy)
}
