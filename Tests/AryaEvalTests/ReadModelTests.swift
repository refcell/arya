import AryaCore
import AryaRuntime
import Testing

@testable import AryaEval

/// Answers by charter name, then case id; unknown answers score as wrong.
private struct NamedRunner: CaseRunner {
    let answers: [String: [String: String]]

    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let id = request.caseItem.id.rawValue
        let choice = answers[request.charter.name]?[id] ?? "none"
        return CaseRunOutcome(
            run: RunID(unchecked: "run_\(request.charter.name)\(id)"),
            result: ["choice": .string(choice)])
    }
}

private let steward = testCharter.id
private let book = try! Casebook(
    name: "triage",
    cases: ["c-1", "c-2", "c-3"].map {
        Case(
            id: CaseID(rawValue: $0)!, input: CaseInput(text: "issue \($0)"),
            expected: ["choice": "bug"])
    })

private func named(_ name: String) -> Charter {
    var charter = testCharter
    charter.name = name
    return charter
}

private func setup(_ answers: [String: [String: String]]) async throws -> (
    MemoryEventSink, CasebookRehearser
) {
    let ambient = Ambient.fixed()
    let sink = MemoryEventSink(ambient: ambient)
    try await StewardLifecycle(sink: sink).create(named("v1"))
    let rehearser = CasebookRehearser(
        runner: NamedRunner(answers: answers), casebooks: FixedCasebooks(book: book), sink: sink,
        ambient: ambient, scorer: ExactScorer(fields: ["choice"]))
    return (sink, rehearser)
}

@Test func backtestComparesVariantsCaseByCase() async throws {
    let (sink, rehearser) = try await setup([
        "v1": ["c-1": "bug", "c-2": "bug"],
        "v2": ["c-1": "feature", "c-2": "bug", "c-3": "bug"],
    ])
    let reports = RehearsalReports(sink: sink, casebooks: FixedCasebooks(book: book))
    let comparison = try await Backtester(rehearser: rehearser, reports: reports).run(
        steward: steward, casebookVersion: book.version,
        current: BacktestVariant(charterVersion: 1, charter: named("v1")),
        proposed: BacktestVariant(charterVersion: 0, charter: named("v2")))

    #expect(comparison.cases.map(\.change) == [.regressed, .unchanged, .improved])
    #expect(comparison.cases.map(\.delta) == [-1, 0, 1])
    #expect(comparison.improved == 1 && comparison.regressed == 1)
    #expect(comparison.current.passed == 2 && comparison.proposed.passed == 2)
    #expect(comparison.meanDelta == 0)
    #expect(!comparison.verdict.passed)
    #expect(comparison.verdict.regressions == [CaseID(rawValue: "c-1")!])
    let first = comparison.cases[0]
    #expect(first.expected == ["choice": "bug"])
    #expect(first.current.actual == ["choice": "bug"])
    #expect(first.proposed.actual == ["choice": "feature"])
    #expect(first.proposed.diff == [FieldDiff(path: "choice", expected: "bug", actual: "feature")])
    #expect(first.proposed.runs == [RunID(unchecked: "run_v2c-1")])
}

@Test func backtestRefusesDifferentCasebooks() async throws {
    let (sink, rehearser) = try await setup(["v1": [:]])
    let other = try Casebook(
        name: "other",
        cases: [Case(id: CaseID(rawValue: "x")!, input: CaseInput(text: "t"), expected: [:])])
    let first = try await rehearser.rehearse(
        RehearsalRequest(steward: steward, charterVersion: 1, casebookVersion: book.version),
        charter: named("v1"))
    var second = rehearser
    second.casebooks = FixedCasebooks(book: other)
    let result = try await second.rehearse(
        RehearsalRequest(steward: steward, charterVersion: 1, casebookVersion: other.version),
        charter: named("v1"))
    struct Both: CasebookSource {
        let books: [Casebook]
        func casebook(version: String) async throws -> Casebook {
            books.first { $0.version == version }!
        }
    }
    let reports = RehearsalReports(sink: sink, casebooks: Both(books: [book, other]))
    await #expect(throws: EvalError.self) {
        try await Backtests(reports: reports).compare(current: first.id!, proposed: result.id!)
    }
}

@Test func readinessExplainsWhyNot() async throws {
    let (sink, rehearser) = try await setup([
        "v1": ["c-1": "bug", "c-2": "bug", "c-3": "bug"], "v1b": ["c-2": "bug", "c-3": "bug"],
    ])
    let readiness = ReadinessReports(sink: sink)
    let request = RehearsalRequest(
        steward: steward, charterVersion: 1, casebookVersion: book.version)
    #expect(try await readiness.report(steward).summary == "not ready: no rehearsal yet")

    let good = try await rehearser.rehearse(request, charter: named("v1"))
    var report = try await readiness.report(steward)
    #expect(report.ready && !report.markedReady)
    #expect(report.summary == "ready: 3/3 passed, no regressions")
    #expect(report.passRate == 1 && report.total == 3 && report.lastRehearsalAt != nil)
    try await Readiness(sink: sink).markReady(
        steward: steward, charterVersion: 1, reviewed: good, person: "person:alex")
    #expect(try await readiness.report(steward).markedReady)

    // Same charter version, but the runner now gets c-1 wrong: a regression below threshold.
    _ = try await rehearser.rehearse(request, charter: named("v1b"))
    try await Corrector(sink: sink, blobs: MemoryBlobs(), ambient: .fixed()).correct(
        CaseCorrection(caseID: CaseID(rawValue: "c-1")!, text: "Login issues are bugs."),
        in: book, steward: steward, person: "person:alex")
    report = try await readiness.report(steward)
    #expect(!report.ready)
    #expect(
        report.reasons.map(\.code) == ["regressions", "below_threshold", "corrections_outstanding"])
    #expect(report.regressions == [CaseID(rawValue: "c-1")!])
    #expect(report.summary == "not ready: c-1 regressed after the last change")
    #expect(report.reasons[1].message == "2/3 passed, 100% required")
    #expect(report.reasons[2].message == "1 correction not yet rehearsed")
    #expect(
        try await readiness.report(steward, threshold: 0.6).reasons.first?.code == "regressions")

    try await StewardLifecycle(sink: sink).updateCharter(named("v2"))
    report = try await readiness.report(steward, threshold: 0.6)
    #expect(report.reasons.first?.code == "stale_rehearsal")
    #expect(
        report.summary
            == "not ready: the charter or its routines changed since the last rehearsal")
    #expect(!report.markedReady)
}

@Test func trendHasFixedWindowsEndingAtEnd() {
    let day = OutcomeMetrics.dayMillis
    let start: Int64 = 1_767_225_600_000
    func event(_ seq: Int, _ type: String, _ millis: Int64, _ payload: JSONValue = [:])
        -> RuntimeEvent
    {
        RuntimeEvent(
            seq: seq, id: EventID(unchecked: "ev_\(seq)"), at: Timestamp(millis: millis),
            draft: RuntimeEventDraft(type: type, steward: steward, actor: .system, payload: payload)
        )
    }
    let events = [
        event(1, "metric.recorded", start - day, ["metric": "triaged_within_1h", "value": 0.1]),
        event(2, "metric.recorded", start + 5, ["metric": "triaged_within_1h", "value": 0.4]),
        event(3, "action.executed", start + 6),
        event(4, "approval.granted", start + 7),
        event(
            5, "metric.recorded", start + 2 * day + 1,
            ["metric": "triaged_within_1h", "value": 0.8]),
    ]
    let trend = OutcomeTrend.build(
        events, steward: steward, metric: testCharter.metric,
        end: Timestamp(millis: start + 3 * day + 9),
        windows: 4)
    #expect(trend.start.millis == start)
    #expect(trend.points == [0.4, nil, 0.8, nil])
    #expect(trend.executed == [1, 0, 0, 0])
    #expect(trend.approvalRates == [1, nil, nil, nil])
    #expect(trend.latest == 0.8)
    #expect(abs((trend.change ?? 0) - 0.4) < 1e-9)
    #expect(trend.improving == true)
    var down = testCharter.metric
    down.direction = .down
    #expect(
        OutcomeTrend.build(
            events, steward: steward, metric: down, end: Timestamp(millis: start + 3 * day),
            windows: 4
        ).improving == false)
}
