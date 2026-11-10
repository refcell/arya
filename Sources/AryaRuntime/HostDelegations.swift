import AryaAdapters
import AryaCore
import AryaLedger
import Foundation

// In-run crews (decision 0052). An adapter may hand part of its work to a child run with
// `host/delegate` and wait for the answer. The child runs through the same crew path as a
// `run/result` delegation (decision 0043): the parent's charter and policy with a budget capped
// at the parent's (`CrewBudget`), `parent` set, its actions recorded as proposals only, and
// `run.delegated` on the parent naming it, so eval groups and scores both kinds alike. At most
// `crew.maxParallel` children of one run run at once; the rest wait. A child, join, or
// replayed run never starts one: a child or join run is refused (depth 1), and a replay
// answers from the recording.

/// One in-run delegation as recorded, for replay: the parent's `run.delegated` and the answer
/// arya sent.
public struct RecordedDelegation: Sendable, Hashable {
    public var delegated: RunDelegated?
    public var answer: HostDelegateResult

    public init(delegated: RunDelegated?, answer: HostDelegateResult) {
        self.delegated = delegated
        self.answer = answer
    }
}

/// Lets at most `width` in-run children of one run run at once.
actor DelegationGate {
    private let width: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(width: Int) { self.width = max(1, width) }

    func acquire() async {
        if running < width {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

extension RunEngine {
    /// Runs the child `params` asks for on behalf of the run `parent` (started by `request`
    /// with `charter`) and returns the answer for the adapter. Ledger errors throw.
    func delegate(
        _ params: HostDelegateParams, parent: RunID, request: RunRequest, charter: Charter,
        gate: DelegationGate
    ) async throws -> HostDelegateResult {
        if request.crewPolicy == .skip {
            guard let recorded = request.delegations[params.id] else {
                return .refused("not_recorded")
            }
            if let delegated = recorded.delegated {
                try await recordDelegated(delegated, request.steward, parent)
            }
            return recorded.answer
        }
        if request.isCrewChild || request.input.kind == .join {
            return try await refuse(params, "depth_limit", request.steward, parent)
        }
        let delegation = RunResult.Delegation(
            id: params.id, title: params.title, input: params.input, adapter: params.adapter,
            effort: params.effort, limits: params.limits)
        let budget: CrewBudget
        switch CrewBudget.requested(by: delegation, charter: charter) {
        case .failure(let refusal):
            return try await refuse(params, refusal.reason, request.steward, parent)
        case .success(let granted):
            budget = granted
        }
        // A re-plan's child is still a crew child: it only proposes.
        let kind: RunInputKind = request.input.kind == .replan ? .manual : request.input.kind
        var child = request.crewMember(RunInput(kind: kind, text: params.input), parent: parent)
        child.crew = budget
        child.replanning = false
        let id = ambient.newID(RunID.self)
        child.id = id
        await gate.acquire()
        let applied = budget.applied(to: charter)
        let outcome: RunOutcome
        do {
            try await recordDelegated(
                RunDelegated(
                    delegation: params.id, title: params.title, child: id,
                    adapter: applied.adapter, effort: applied.effort, limits: applied.limits),
                request.steward, parent)
            outcome = try await run(child)
        } catch {
            await gate.release()
            throw error
        }
        await gate.release()
        return Self.answer(outcome)
    }

    /// The `host/delegate` answer for a child's outcome.
    static func answer(_ outcome: RunOutcome) -> HostDelegateResult {
        let run = outcome.run.rawValue
        switch outcome.phase {
        case .finished(.completed):
            let result = outcome.result.flatMap { try? Payload.encode($0) }
            return HostDelegateResult(run: run, status: .completed, result: result)
        case .finished(.stopped):
            return HostDelegateResult(run: run, status: .stopped, result: nil)
        case .failed(let reason):
            return HostDelegateResult(run: run, status: .failed, reason: reason.rawValue)
        default:
            return HostDelegateResult(run: run, status: .failed, reason: "unfinished")
        }
    }

    private func refuse(
        _ params: HostDelegateParams, _ reason: String, _ steward: StewardID, _ parent: RunID
    ) async throws -> HostDelegateResult {
        try await recordDelegated(
            RunDelegated(delegation: params.id, title: params.title, refused: reason), steward,
            parent)
        return .refused(reason)
    }
}
