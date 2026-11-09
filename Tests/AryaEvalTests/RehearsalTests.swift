import AryaCore
import Foundation
import Testing

@testable import AryaEval

struct FixedCasebooks: CasebookSource {
    var book: Casebook
    func casebook(version: String) async throws -> Casebook { book }
}

struct RunnerFailure: Error {}

/// Answers each case from a table; tracks peak concurrency. Unknown cases throw; cases in
/// `leaks` report a leak. Sleeps in reverse case order so completion order differs from job
/// order.
actor ScriptedRunner: CaseRunner {
    let answers: [String: JSONValue]
    let leaks: Set<String>
    var active = 0
    var peak = 0
    var calls: [String] = []

    init(answers: [String: JSONValue], leaks: Set<String> = []) {
        self.answers = answers
        self.leaks = leaks
    }

    func run(_ request: CaseRunRequest) async throws -> CaseRunOutcome {
        let key = request.caseItem.id.rawValue
        calls.append("\(key)#\(request.sample)")
        active += 1
        peak = max(peak, active)
        let delay = UInt64(10 - min(9, calls.count)) * 1_000_000
        try? await Task.sleep(nanoseconds: delay)
        active -= 1
        guard let answer = answers[key] else { throw RunnerFailure() }
        let run = RunID(
            unchecked: "run_\(key.replacingOccurrences(of: "-", with: ""))\(request.sample)")
        return CaseRunOutcome(run: run, result: answer, leak: leaks.contains(key))
    }
}

private func makeBook() throws -> Casebook {
    try Casebook(
        name: "triage",
        cases: ["c-3", "c-1", "c-2", "c-4"].map {
            EvalCase(
                id: CaseID(rawValue: $0)!, input: ["kind": "case"], expected: ["choice": "bug"])
        })
}

private func rehearser(
    _ runner: ScriptedRunner, _ recorder: MemoryRecorder, parallel: Int
) throws -> CasebookRehearser {
    CasebookRehearser(
        runner: runner, casebooks: FixedCasebooks(book: try makeBook()),
        scorer: ExactScorer(fields: ["choice"]), recorder: recorder, ambient: .fixed(),
        maxParallel: parallel)
}

@Test func rehearsalScoresRecordsAndBoundsParallelism() async throws {
    let runner = ScriptedRunner(
        answers: [
            "c-1": ["choice": "bug"], "c-2": ["choice": "feature"], "c-3": ["choice": "bug"],
        ],
        leaks: ["c-3"])
    let recorder = MemoryRecorder()
    let request = RehearsalRequest(
        steward: StewardID(unchecked: "st_triage"), charterVersion: 2, casebookVersion: "x",
        samples: 2)
    let result = try await rehearser(runner, recorder, parallel: 3).rehearse(request)

    #expect(await runner.peak <= 3)
    #expect(await runner.calls.count == 8)
    #expect(result.outcomes.map(\.caseID.rawValue) == ["c-1", "c-2", "c-3", "c-4"])
    #expect(
        result.outcomes.map { $0.samples.map(\.passed) } == [
            [true, true], [false, false], [false, false], [false, false],
        ])
    #expect(result.outcomes.map(\.leak) == [false, false, true, false])
    #expect(result.outcomes[3].samples[0].notes == ["run failed: RunnerFailure()"])

    let events = await recorder.events
    #expect(
        events.map(\.type) == [
            "rehearsal.started", "rehearsal.case.scored", "rehearsal.case.scored",
            "rehearsal.case.scored", "rehearsal.case.scored", "rehearsal.finished",
        ])
    #expect(
        events.dropFirst().prefix(4).map { $0.payload["case"] } == [
            "c-1", "c-2", "c-3", "c-4",
        ])
    #expect(events[1].payload["runs"] == ["run_c10", "run_c11"])
    #expect(events[5].payload["passed"] == 1)
    #expect(events[5].payload["leaks"] == 1)
    #expect(events[5].payload["meanScore"] == 0.25)
    #expect(events[0].payload["rehearsal"] == .string(result.id?.rawValue ?? ""))
}

@Test func rehearsalEventsAreIdenticalAcrossParallelism() async throws {
    let answers: [String: JSONValue] = [
        "c-1": ["choice": "bug"], "c-2": ["choice": "bug"], "c-3": ["choice": "x"],
        "c-4": ["choice": "bug"],
    ]
    let request = RehearsalRequest(
        steward: StewardID(unchecked: "st_triage"), charterVersion: 1, casebookVersion: "x")
    var logs: [[String]] = []
    for parallel in [1, 4] {
        let recorder = MemoryRecorder()
        _ = try await rehearser(ScriptedRunner(answers: answers), recorder, parallel: parallel)
            .rehearse(request)
        logs.append(
            try await recorder.events.map { try CanonicalJSON.string($0.payload) })
    }
    #expect(logs[0] == logs[1])
}
