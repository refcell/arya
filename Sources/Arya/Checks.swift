import AryaCore
import AryaEval
import AryaRuntime
import Foundation

extension Workspace {
    /// The checks people taught a steward through corrections and review-queue agreements,
    /// versioned and scored on its newest live rehearsal; `nil` before anyone reviewed a case.
    /// Each correction and review rebuilds them, so the newest version is always current.
    public func learnedChecks(steward: String) async throws -> LearnedChecksSummary? {
        let id = try await existing(steward).id
        return try await LearnedChecks(sink: sink, casebooks: casebookSource).view(steward: id)
    }

    /// Whether the steward is ready to go live after onboarding: `agreed` agreed reviews (or
    /// every case of a smaller queue), a passing live rehearsal, and every learned check
    /// rehearsed and green. For onboarding's "Ready to go live" step.
    public func goLiveGate(steward: String, agreed: Int = GoLiveGate.defaultAgreed)
        async throws -> GoLiveSummary
    {
        let id = try await existing(steward).id
        return GoLiveGate.evaluate(
            steward: steward, review: try await reviewQueue(steward: steward),
            readiness: try await ReadinessReports(sink: readSink).report(id),
            checks: try await learnedChecks(steward: steward), agreed: agreed)
    }

    /// Trajectory grading: each of the steward's runs graded on the follow-up checks that came
    /// after it, with credit for its action kinds and decision choices and a confidence that
    /// weighs how much evidence there is (for Impact).
    public func trajectories(steward: String) async throws -> TrajectorySummary {
        let id = try await existing(steward).id
        return TrajectoryGrades.view(steward: id, events: try facadeState().bySteward[id] ?? [])
    }

    /// Runs runtime's follow-up checks (decision 0053) due now, answering each binding's
    /// `outcome` call with `answer(target, kind)` instead of spawning the binding. For seeding
    /// a demo home whose bindings are scripts; returns how many checks were recorded.
    public func checkOutcomes(
        delay: Int64, answer: @escaping @Sendable (String, String) -> JSONValue
    ) async throws -> Int {
        let checker = OutcomeChecker(sink: sink, delay: delay) { _ in
            AnsweringUpstream(answer: answer)
        }
        return try await checker.check(now: ambient.now()).checked.count
    }

    /// Records a new version of the steward's learned checks when its corrections or
    /// agreements changed them.
    func rebuildChecks(_ steward: StewardID, by person: String) async throws {
        try await LearnedChecks(sink: sink, casebooks: casebookSource)
            .build(steward: steward, actor: .person(person))
    }
}

/// A steward's learned checks, scored, as the CLI and app read them.
public typealias LearnedChecksSummary = LearnedChecksView
/// One learned check and whether the newest live rehearsal passes it.
public typealias LearnedCheckLine = LearnedCheckResult
public typealias GoLiveSummary = GoLiveGateResult
public typealias TrajectorySummary = TrajectoryGradesView

/// A binding that answers only `outcome`, from a closure (`Workspace.checkOutcomes`).
private struct AnsweringUpstream: ToolUpstream {
    let answer: @Sendable (String, String) -> JSONValue

    func listTools() async throws -> [JSONValue] { [] }

    func call(_ tool: String, arguments: JSONValue) async throws -> JSONValue {
        let body = answer(
            arguments["target"]?.stringValue ?? "", arguments["action"]?.stringValue ?? "")
        return ["structuredContent": body]
    }

    func close() async {}
}
