import AryaCore
import AryaRuntime
import Testing

@testable import AryaEval

@Test func resultDiffComparesOnlyWhatTheCaseStates() {
    let expected: JSONValue = [
        "decisions": [["choice": "bug"]],
        "actions": [["kind": "label", "target": "tracker:ISSUE-1"]],
    ]
    let actual: JSONValue = [
        "summary": "ignored",
        "decisions": [["choice": "feature", "id": "d1"]],
        "actions": [
            ["kind": "label", "target": "tracker:ISSUE-1"], ["kind": "route", "target": "x"],
        ],
    ]
    #expect(
        ResultDiff.diff(expected: expected, actual: actual) == [
            FieldDiff(
                path: "actions[1]", expected: .none, actual: ["kind": "route", "target": "x"]),
            FieldDiff(path: "decisions[0].choice", expected: "bug", actual: "feature"),
        ])
    #expect(ResultDiff.diff(expected: expected, actual: expected).isEmpty)
    #expect(
        ResultDiff.diff(expected: ["choice": "bug"], actual: nil) == [
            FieldDiff(path: "", expected: ["choice": "bug"], actual: .none)
        ])
}

@Test func reportShowsExpectedVersusActualAndCorrections() async throws {
    let ambient = Ambient.fixed()
    let sink = MemoryEventSink(ambient: ambient)
    let blobs = MemoryBlobs()
    let steward = StewardID(unchecked: "st_triage")
    let book = try Casebook(
        name: "triage",
        cases: ["c-1", "c-2", "c-3"].map {
            Case(
                id: CaseID(rawValue: $0)!, input: CaseInput(text: "issue \($0)"),
                expected: ["choice": "bug"])
        })
    let runner = ScriptedRunner(
        answers: ["c-1": ["choice": "bug"], "c-2": ["choice": "feature"]], leaks: [])
    let rehearser = CasebookRehearser(
        runner: runner, casebooks: FixedCasebooks(book: book), sink: sink, ambient: ambient,
        scorer: ExactScorer(fields: ["choice"]))
    let result = try await rehearser.rehearse(
        RehearsalRequest(steward: steward, charterVersion: 1, casebookVersion: book.version),
        charter: testCharter)
    let id = try #require(result.id)
    try await Corrector(sink: sink, blobs: blobs, ambient: ambient).correct(
        CaseCorrection(
            caseID: CaseID(rawValue: "c-2")!, text: "Feature requests are not bugs.",
            expected: ["choice": "feature"], rehearsal: id),
        in: book, steward: steward, person: "person:alex")

    let report = try await RehearsalReports(sink: sink, casebooks: FixedCasebooks(book: book))
        .report(id)
    #expect(report.finished)
    #expect(report.passed == 1)
    #expect(report.casebook == "triage")
    #expect(report.cases.map(\.caseID.rawValue) == ["c-1", "c-2", "c-3"])
    let (pass, wrong, failed) = (report.cases[0], report.cases[1], report.cases[2])
    #expect(pass.passed && pass.samples.first?.diff == [])
    #expect(!wrong.passed)
    #expect(wrong.input == "issue c-2")
    #expect(wrong.samples.first?.run == RunID(unchecked: "run_c20"))
    #expect(
        wrong.samples.first?.diff == [
            FieldDiff(path: "choice", expected: "bug", actual: "feature")
        ])
    #expect(wrong.corrections.map(\.text) == ["Feature requests are not bugs."])
    #expect(failed.samples.first?.actual == .some(.none))
    #expect(failed.samples.first?.score.notes.first?.hasPrefix("run failed") == true)
    #expect(pass.corrections.isEmpty)
}

@Test func reportOfAnUnknownRehearsalThrows() async throws {
    let sink = MemoryEventSink(ambient: .fixed())
    let book = try Casebook(name: "triage", cases: [])
    let id = RehearsalID(unchecked: "rh_missing")
    await #expect(throws: EvalError.unknownRehearsal(id)) {
        try await RehearsalReports(sink: sink, casebooks: FixedCasebooks(book: book)).report(id)
    }
}
