import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
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

/// Runs each case through the engine in rehearsal mode, like the facade's case runner.
private struct EngineCaseRunner: CaseRunner {
    let engine: RunEngine

    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let item = request.caseItem
        var run = RunRequest(
            steward: request.steward,
            input: RunInput(kind: .case, text: item.input.text, attachments: []),
            mode: .rehearsal(item.context), actor: .system)
        run.rehearsal = RehearsalTag(
            rehearsal: request.rehearsal, caseID: item.id, sample: request.sample + 1)
        let outcome = try await engine.run(run)
        let result = try outcome.result.map { try CanonicalJSON.jsonValue($0) } ?? [:]
        return CaseRunOutcome(run: outcome.run, result: result, leak: outcome.leak)
    }
}

@Test func replayOfARehearsalRunUsesTheStoredCase() async throws {
    let ambient = Ambient.fixed(stepMillis: 7, seed: 9)
    let sink = MemoryEventSink(ambient: ambient)
    let blobs = MemoryBlobs()
    try await StewardLifecycle(sink: sink).create(inboxCharter())
    let line = """
        {"v":1,"id":"c1","input":{"kind":"case","text":"New message MSG-1"},\
        "context":{"toolResults":[{"tool":"inbox.get","input":{"id":"MSG-1"},\
        "output":{"subject":"Invoice"}}]},"expected":{"decisions":[{"choice":"billing"}]}}
        """
    let (book, _) = try await CasebookImporter(blobs: blobs, sink: sink)
        .importCasebook(name: "inbox", data: Data(line.utf8), steward: steward)
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let engine = RunEngine(
        sink: sink, ambient: ambient, adapters: FakeAdapters(script: script),
        dispatcher: ActionDispatcher(
            sink: sink, approvals: approvals, executor: RecordingExecutor(outcomes: [:])),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    let casebooks = StoredCasebooks(sink: sink, blobs: blobs)
    let rehearser = CasebookRehearser(
        runner: EngineCaseRunner(engine: engine), casebooks: casebooks, sink: sink,
        ambient: ambient)
    _ = try await rehearser.rehearse(
        RehearsalRequest(steward: steward, charterVersion: 1, casebookVersion: book.version),
        charter: inboxCharter())
    let started = try await sink.events(from: 1).first { $0.type == "run.started" }
    let run = try #require(started?.draft.run)

    #expect(try await RunReplayer(sink: sink, casebooks: casebooks).replay(run: run).passed)
    await #expect(throws: EvalError.self) {
        try await RunReplayer(sink: sink).replay(run: run)
    }
}

@Test func correctingALiveRunAddsItAsACase() async throws {
    let (sink, run) = try await recordRun()
    let blobs = MemoryBlobs()
    let other = #"{"v":1,"id":"c1","input":{"text":"t"},"expected":{}}"#
    let (book, _) = try await CasebookImporter(blobs: blobs, sink: sink)
        .importCasebook(name: "inbox", data: Data(other.utf8), steward: steward)
    #expect(
        try RunCases.did(try await sink.events(from: 1), run: run) == [
            "decisions": [["choice": "billing"]],
            "actions": [
                ["kind": "label", "target": "inbox:MSG-1"],
                ["kind": "route", "target": "inbox:MSG-1"],
            ],
        ])

    let want: JSONValue = ["decisions": [["choice": "how-to"]]]
    let outcome = try await Corrector(sink: sink, blobs: blobs, ambient: .fixed(seed: 4)).correct(
        run: run, expected: want, note: "Questions about invoices are how-to.", in: book,
        steward: steward, person: "person:alex")
    let corrected = try #require(outcome.casebook)
    let caseID = try RunCases.caseID(for: run)
    let added = try #require(corrected.cases.first { $0.id == caseID })
    #expect(corrected.cases.count == 2)
    #expect(added.expected == want)
    #expect(added.input.text == "New message MSG-1")
    #expect(added.context.toolResults.map(\.tool) == [])
    #expect(outcome.note.text == "Questions about invoices are how-to.")
    let stored = StoredCasebooks(sink: sink, blobs: blobs)
    #expect(try await stored.latest(name: "inbox") == corrected)

    // Correcting the same run again updates its case instead of adding another.
    let again = try await Corrector(sink: sink, blobs: blobs, ambient: .fixed(seed: 5)).correct(
        run: run, expected: ["decisions": [["choice": "billing"]]], note: "Back to billing.",
        in: corrected, steward: steward, person: "person:alex")
    #expect(again.casebook?.cases.count == 2)
}

/// Answers by charter: a charter whose first guardrail mentions how-to chooses how-to.
private struct WhatIfRunner: CaseRunner {
    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let choice =
            request.charter.guardrails.first?.contains("how-to") == true ? "how-to" : "billing"
        return CaseRunOutcome(
            run: RunID(unchecked: "run_whatif"),
            result: [
                "decisions": [["choice": .string(choice)]],
                "actions": [
                    ["kind": "label", "target": "inbox:MSG-1"],
                    ["kind": "route", "target": "inbox:MSG-1"],
                ],
            ])
    }
}

@Test func whatIfReplaysOneRunUnderAProposedCharter() async throws {
    let (sink, run) = try await recordRun()
    var proposed = inboxCharter()
    proposed.guardrails = ["Invoice questions are how-to."]
    let whatIf = Counterfactuals(sink: sink, runner: WhatIfRunner(), ambient: .fixed(seed: 8))

    let same = try await whatIf.whatIf(run: run, charter: inboxCharter())
    #expect(same.diff.isEmpty)
    #expect(
        same.summary
            == "with the change it would have done the same: chose billing; "
            + "label inbox:MSG-1, route inbox:MSG-1")

    let changed = try await whatIf.whatIf(run: run, charter: proposed)
    #expect(
        changed.diff == [
            FieldDiff(path: "decisions[0].choice", expected: "billing", actual: "how-to")
        ])
    #expect(changed.fixesCorrection == nil)
    #expect(
        changed.summary
            == "with the change it would have: chose how-to; label inbox:MSG-1, route inbox:MSG-1 "
            + "(did: chose billing; label inbox:MSG-1, route inbox:MSG-1)")
    #expect(changed.rehearsalRun == RunID(unchecked: "run_whatif"))

    // After a person corrects the run to how-to, the proposed charter fixes it.
    try await Corrector(sink: sink, blobs: MemoryBlobs(), ambient: .fixed(seed: 9)).correct(
        run: run, expected: ["decisions": [["choice": "how-to"]]], note: "How-to.",
        in: try Casebook(name: "inbox", cases: []), steward: steward, person: "person:alex")
    let fixed = try await whatIf.whatIf(run: run, charter: proposed)
    #expect(fixed.fixesCorrection == true)
    #expect(fixed.summary.hasSuffix(", which fixes the correction"))
    // The question never shows up as a rehearsal.
    #expect(try RehearsalBook(try await sink.events(from: 1)).records.isEmpty)
}

@Test func scoresReadAsOneSentence() throws {
    let rubric = RubricScorer(checks: [
        RubricCheck(kind: .equals, path: "reply.tone", value: "polite"),
        RubricCheck(kind: .contains, path: "reply.text", value: "policy"),
        RubricCheck(kind: .absent, path: "reply.refund"),
    ]).score(
        expected: [:],
        actual: ["reply": ["tone": "polite", "text": "Per our policy, …"]])
    #expect(rubric.sentence == "tone: polite, text mentions policy, no refund")
    let exact = ExactScorer(fields: ["decisions.choice"]).score(
        expected: ["decisions": [["choice": "billing"]]],
        actual: ["decisions": [["choice": "how-to"]]])
    #expect(exact.sentence == "choice: how-to, not billing")
    #expect(
        try JudgeVerdict(
            result: ["value": 1, "notes": ["tone: polite", "  matches\npolicy ", ""]],
            passThreshold: 1
        ).score(judge: "fake").sentence == "tone: polite, matches policy")
    #expect(CaseScore(value: 0, passed: false, notes: ["leak"]).sentence == "failed (0): leak")
}
