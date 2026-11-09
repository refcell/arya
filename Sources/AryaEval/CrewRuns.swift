import AryaAdapters
import AryaCore
import AryaRuntime

extension RunEngine {
    /// Runs `request` and, when it is a top-level rehearsal whose result delegates, its crew in
    /// rehearsal mode too: each child and then the join run, with the parent's case context,
    /// rehearsal tag, and charter. The runtime fans out only live runs on its own.
    public func runWithCrew(_ request: RunRequest, charter: Charter) async throws -> RunOutcome {
        var outcome = try await run(request)
        guard case .rehearsal = request.mode, request.parent == nil, request.input.kind != .join,
            outcome.crew == nil, let delegations = outcome.result?.delegations,
            !delegations.isEmpty
        else { return outcome }
        outcome.crew = try await runCrew(
            delegations, parent: outcome.run, request: request, charter: charter)
        return outcome
    }
}

extension RunOutcome {
    /// The outcome a case is scored on: the join run's result when the run delegated to a
    /// crew, else the run's own result. `nil` when the deciding run failed.
    public var finalResult: RunResult? {
        guard let crew else { return result }
        return crew.join.result
    }

    /// True when the run or any run of its crew leaked.
    public var leakedAnywhere: Bool {
        leak || (crew.map { $0.join.leak || $0.children.contains(where: \.leak) } ?? false)
    }
}
