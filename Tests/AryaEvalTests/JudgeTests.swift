import AryaAdapters
import AryaCore
import AryaRuntime
import Testing

@testable import AryaEval

private struct JudgeAdapters: AdapterFactory {
    var result: JSONValue

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        FakeAdapter(script: FakeScript(runs: [FakeScript.Run(result: result)]))
    }
}

private let judgeCharter = Charter(
    id: StewardID(unchecked: "st_judge"), name: "Judge", outcome: "Scores results fairly.",
    metric: Metric(name: "agreement", unit: "ratio", direction: .up), adapter: "fake")

private let request = JudgeRequest(
    rehearsal: RehearsalID(unchecked: "reh_1"), caseID: CaseID(rawValue: "c-1")!, sample: 0,
    input: "issue", expected: ["choice": "bug"], actual: ["choice": "defect"],
    rubric: "A synonym of the expected choice passes.")

@Test func verdictsAreValidated() throws {
    #expect(
        try JudgeVerdict(result: ["value": 0.75, "notes": ["close"]], passThreshold: 0.7)
            == JudgeVerdict(value: 0.75, passed: true, notes: ["close"]))
    #expect(
        try JudgeVerdict(result: ["value": 1, "passed": false], passThreshold: 0.5).passed == false)
    #expect(try JudgeVerdict(result: ["value": 0], passThreshold: 0.5).passed == false)
    for bad: JSONValue? in [
        nil, ["value": 1.5], ["value": "high"], ["value": 0.5, "passed": "yes"],
        ["value": 0.5, "notes": [1]],
    ] {
        #expect(throws: EvalError.self) { try JudgeVerdict(result: bad, passThreshold: 0.5) }
    }
}

@Test func adapterJudgeScoresWithAnyAdapter() async throws {
    let judge = AdapterJudge(
        adapters: JudgeAdapters(result: ["value": 0.9, "notes": ["synonym"]]),
        charter: judgeCharter, passThreshold: 0.8, ambient: .fixed())
    #expect(
        try await judge.judge(request) == JudgeVerdict(value: 0.9, passed: true, notes: ["synonym"])
    )
    #expect(judge.name == "fake")

    let lying = AdapterJudge(
        adapters: JudgeAdapters(result: ["value": 7]), charter: judgeCharter, ambient: .fixed())
    await #expect(throws: EvalError.self) { try await lying.judge(request) }
}

@Test func rehearsalRecordsJudgmentsAndReplaysThem() async throws {
    let ambient = Ambient.fixed()
    let sink = MemoryEventSink(ambient: ambient)
    let book = try Casebook(
        name: "triage",
        cases: ["c-1", "c-2"].map {
            Case(
                id: CaseID(rawValue: $0)!, input: CaseInput(text: "issue"),
                expected: ["choice": "bug"])
        })
    let runner = ScriptedRunner(answers: ["c-1": ["choice": "defect"], "c-2": ["choice": "bug"]])
    let judge = AdapterJudge(
        adapters: JudgeAdapters(result: ["value": 0.9]), charter: judgeCharter,
        passThreshold: 0.8, ambient: ambient)
    let rehearser = CasebookRehearser(
        runner: runner, casebooks: FixedCasebooks(book: book), sink: sink, ambient: ambient,
        scorer: ExactScorer(fields: ["choice"]), judge: judge, rubric: "Synonyms pass.")
    let result = try await rehearser.rehearse(
        RehearsalRequest(steward: testCharter.id, charterVersion: 1, casebookVersion: book.version),
        charter: testCharter)
    // The exact scorer would fail c-1; the judge passes both.
    #expect(result.outcomes.map { $0.samples.map(\.value) } == [[0.9], [0.9]])

    let events = try await sink.events(from: 1)
    let scored = try events.filter { $0.type == EvalEventType.rehearsalCaseScored }
        .map { try EvalPayload.decode(RehearsalCaseScoredPayload.self, $0.payload) }
    #expect(scored.first?.judgments?.first?.judge == "fake")
    #expect(scored.first?.judgments?.first?.rubric == "Synonyms pass.")
    #expect(result.outcomes.first?.samples.first?.text == "passed (0.9)")
    #expect(result.outcomes.first?.samples.first?.checks?.first?.label == "judge fake")
    let report = try await RehearsalReports(sink: sink, casebooks: FixedCasebooks(book: book))
        .report(try #require(result.id))
    #expect(report.cases.first?.samples.first?.judgment?.verdict?.value == 0.9)
    #expect(report.cases.first?.samples.first?.scoreText == "passed (0.9)")

    var replayRequest = request
    replayRequest.rehearsal = try #require(result.id)
    let recorded = try RecordedJudge(events: events)
    #expect(try await recorded.judge(replayRequest).value == 0.9)
    replayRequest.sample = 3
    await #expect(throws: EvalError.self) { try await recorded.judge(replayRequest) }
}

@Test func aFailingJudgeScoresZero() async throws {
    let ambient = Ambient.fixed()
    let sink = MemoryEventSink(ambient: ambient)
    let book = try Casebook(
        name: "triage",
        cases: [Case(id: CaseID(rawValue: "c-1")!, input: CaseInput(text: "i"), expected: [:])])
    let rehearser = CasebookRehearser(
        runner: ScriptedRunner(answers: ["c-1": [:]]), casebooks: FixedCasebooks(book: book),
        sink: sink, ambient: ambient,
        judge: AdapterJudge(
            adapters: JudgeAdapters(result: ["value": -1]), charter: judgeCharter,
            ambient: ambient),
        rubric: "Anything.")
    let result = try await rehearser.rehearse(
        RehearsalRequest(steward: testCharter.id, charterVersion: 1, casebookVersion: book.version),
        charter: testCharter)
    let score = try #require(result.outcomes.first?.samples.first)
    #expect(score.value == 0 && !score.passed)
    #expect(score.text == "failed (0): judge fake: judge failed: value must be a number in 0...1")
    let payload = try await sink.events(from: 1)
        .first { $0.type == EvalEventType.rehearsalCaseScored }
        .map { try EvalPayload.decode(RehearsalCaseScoredPayload.self, $0.payload) }
    #expect(payload?.judgments?.first?.verdict == nil)
    #expect(payload?.judgments?.first?.error != nil)
}
