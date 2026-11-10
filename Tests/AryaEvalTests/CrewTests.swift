import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import AryaEval

private let crewSteward = StewardID(unchecked: "st_crew")

private func crewCharter() -> Charter {
    var charter = Charter(
        id: crewSteward, name: "Crew triage", outcome: "Every issue is triaged by a crew.",
        metric: Metric(name: "triaged", unit: "ratio", direction: .up), adapter: "fake")
    charter.crew = Crew(maxParallel: 1)
    return charter
}

/// The parent splits the work; each child decides; the join decides the final outcome.
private func crewScript(join choice: String) -> FakeScript {
    FakeScript(runs: [
        FakeScript.Run(
            input: "Issue ISSUE-1",
            result: [
                "summary": "Split the triage.",
                "delegations": [
                    ["id": "d1", "title": "Check logs", "input": "check logs"],
                    ["id": "d2", "title": "Check history", "input": "check history"],
                ],
            ]),
        FakeScript.Run(
            input: "check logs",
            result: ["summary": "logs", "decisions": [["id": "c1", "choice": "bug"]]]),
        FakeScript.Run(
            input: "check history",
            result: ["summary": "history", "decisions": [["id": "c2", "choice": "bug"]]]),
        FakeScript.Run(
            result: [
                "summary": "Joined.", "decisions": [["id": "j1", "choice": .string(choice)]],
            ]),
    ])
}

private struct ScriptAdapters: AdapterFactory {
    let script: FakeScript

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        FakeAdapter(script: script)
    }
}

private func crewEngine(_ sink: MemoryEventSink, _ ambient: Ambient, join: String) -> RunEngine {
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    return RunEngine(
        sink: sink, ambient: ambient, adapters: ScriptAdapters(script: crewScript(join: join)),
        dispatcher: ActionDispatcher(
            sink: sink, approvals: approvals, executor: RecordingExecutor(outcomes: [:])),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
}

/// Runs cases the way the facade does: crews in rehearsal mode, scored on the final outcome.
private struct CrewCaseRunner: CaseRunner {
    let engine: RunEngine

    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let item = request.caseItem
        var run = RunRequest(
            steward: request.steward, input: RunInput(kind: .case, text: item.input.text),
            mode: .rehearsal(item.context), actor: .system)
        run.rehearsal = RehearsalTag(
            rehearsal: request.rehearsal, caseID: item.id, sample: request.sample + 1)
        let outcome = try await engine.runWithCrew(run, charter: request.charter)
        let result = try outcome.finalResult.map { try CanonicalJSON.jsonValue($0) } ?? [:]
        return CaseRunOutcome(run: outcome.run, result: result, leak: outcome.leakedAnywhere)
    }
}

@Test func rehearsalRunsTheCrewAndScoresTheJoin() async throws {
    let ambient = Ambient.fixed(stepMillis: 3, seed: 61)
    let sink = MemoryEventSink(ambient: ambient)
    try await StewardLifecycle(sink: sink).create(crewCharter())
    let book = try Casebook(
        name: "crew",
        cases: [
            Case(
                id: CaseID(rawValue: "case-1")!, input: CaseInput(text: "Issue ISSUE-1"),
                expected: ["decisions": [["choice": "feature"]]])
        ])
    let score = { (join: String) async throws -> RehearsalResult in
        try await CasebookRehearser(
            runner: CrewCaseRunner(engine: crewEngine(sink, ambient, join: join)),
            casebooks: FixedCasebooks(book: book), sink: sink, ambient: ambient,
            scorer: ExactScorer(fields: ["decisions.choice"])
        ).rehearse(
            RehearsalRequest(
                steward: crewSteward, charterVersion: 1, casebookVersion: book.version),
            charter: crewCharter())
    }
    // The children decide `bug`; only the join's `feature` matches the case.
    let joined = try await score("feature")
    #expect(joined.outcomes[0].samples[0].passed)
    let split = try await score("bug")
    #expect(!split.outcomes[0].samples[0].passed)

    // Every crew run is a rehearsal run under its parent; nothing ran live.
    let runs = try RunBook(try await sink.events(from: 1)).all
    #expect(runs.count == 8)
    #expect(runs.allSatisfy { $0.rehearsal })
    #expect(runs.filter { $0.parent == nil }.count == 2)
    #expect(runs.filter { $0.trigger == "join" }.count == 2)
}

@Test func replayOfACrewRunReplaysChildrenAndJoin() async throws {
    let ambient = Ambient.fixed(stepMillis: 3, seed: 62)
    let sink = MemoryEventSink(ambient: ambient)
    try await StewardLifecycle(sink: sink).create(crewCharter())
    let outcome = try await crewEngine(sink, ambient, join: "feature").run(
        .manual(crewSteward, text: "Issue ISSUE-1"))
    let crew = try #require(outcome.crew)

    let report = try await RunReplayer(sink: sink).replay(run: outcome.run)
    #expect(report.passed)
    #expect(report.divergence == nil)
    #expect(report.crew?.map(\.run) == crew.children.map(\.run) + [crew.join.run])
    #expect(report.crew?.allSatisfy { $0.passed && $0.comparedEvents > 2 } == true)

    // A crew run that drifts fails the whole report, and says which run diverged.
    let drifted = try await RunReplayer(sink: sink).replay(run: crew.join.run)
    #expect(drifted.passed && drifted.crew == nil)
}

@Test func readinessSentenceWording() {
    func say(_ counts: ReadinessCounts) -> String { counts.sentence }
    #expect(
        say(ReadinessCounts(passed: 8, total: 8, gatePassed: true, checked: 20))
            == "Ready: casebook 8/8, none of last 20 runs would change")
    #expect(
        say(ReadinessCounts(passed: 8, total: 8, gatePassed: true, checked: 20, improved: 2))
            == "Ready: casebook 8/8, 2 of last 20 runs would improve")
    #expect(
        say(ReadinessCounts(passed: 8, total: 8, gatePassed: true, checked: 1))
            == "Ready: casebook 8/8, the last run would not change")
    #expect(
        say(ReadinessCounts(passed: 8, total: 8, gatePassed: true, checked: 0))
            == "Ready: casebook 8/8, no recent runs to check")
    #expect(
        say(ReadinessCounts(passed: 7, total: 8, gatePassed: true, checked: 20, changed: 2))
            == "Not ready: 2 of last 20 runs would change")
    #expect(
        say(
            ReadinessCounts(
                passed: 7, total: 8, gatePassed: false, gateReason: "case regressed",
                regressedCases: ["case-0005"], checked: 20, changed: 2, failed: 1))
            == "Not ready: case-0005 would regress; 2 of last 20 runs would change; "
            + "1 of last 20 runs would fail")
    #expect(
        say(
            ReadinessCounts(
                passed: 3, total: 8, gatePassed: false,
                regressedCases: ["c1", "c2", "c3", "c4", "c5"], checked: 1, changed: 1))
            == "Not ready: c1, c2, c3 and 2 more would regress; the last run would change")
    #expect(
        say(
            ReadinessCounts(
                passed: 6, total: 8, gatePassed: false, regressedCases: ["c1", "c2"], checked: 0))
            == "Not ready: c1 and c2 would regress")
    #expect(
        say(
            ReadinessCounts(
                passed: 6, total: 8, gatePassed: false, gateReason: "mean below baseline",
                checked: 5))
            == "Not ready: casebook gate failed: mean below baseline")
    #expect(
        say(ReadinessCounts(passed: 0, total: 0, gatePassed: false, checked: 0))
            == "Not ready: casebook gate failed")
    // Every sentence is one line with no trailing punctuation.
    #expect(!say(ReadinessCounts(passed: 1, total: 1, gatePassed: true, checked: 3)).contains("\n"))
}

/// The parent hands one check to a child in the middle of its run and waits for it.
private func inRunScript() -> FakeScript {
    FakeScript(runs: [
        FakeScript.Run(
            input: "Issue ISSUE-2",
            steps: [.delegate(id: "d1", title: "Check logs", input: "check logs")],
            result: ["summary": "Used the logs.", "decisions": [["id": "p1", "choice": "bug"]]]),
        FakeScript.Run(
            input: "check logs",
            result: ["summary": "logs", "decisions": [["id": "c1", "choice": "bug"]]]),
    ])
}

@Test func anInRunDelegationIsACrewMemberAndReplaysFromTheRecording() async throws {
    let ambient = Ambient.fixed(stepMillis: 3, seed: 63)
    let sink = MemoryEventSink(ambient: ambient)
    try await StewardLifecycle(sink: sink).create(crewCharter())
    let approvals = ApprovalQueue(sink: sink, ambient: ambient)
    let engine = RunEngine(
        sink: sink, ambient: ambient, adapters: ScriptAdapters(script: inRunScript()),
        dispatcher: ActionDispatcher(
            sink: sink, approvals: approvals, executor: RecordingExecutor(outcomes: [:])),
        approvals: approvals, workdir: { "scratch/\($0.rawValue)" })
    let outcome = try await engine.run(.manual(crewSteward, text: "Issue ISSUE-2"))
    #expect(outcome.phase == .finished(.completed))
    let events = try await sink.events(from: 1)
    // Scored like a result delegation: the child is a member of the parent's crew tree.
    let members = try CrewTree.members(events, of: outcome.run)
    #expect(members.count == 2)

    let report = try await RunReplayer(sink: sink).replay(run: outcome.run)
    #expect(report.passed)
    #expect(report.divergence == nil)
    #expect(report.crew?.map(\.run) == [members[1]])
}
