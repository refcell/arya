import AryaAdapters
import AryaCore

// Crews (ARCHITECTURE.md "Crews"). After a live top-level run finishes with `delegations`, each
// delegation becomes a child run (`parent` = that run) under the parent's charter, at most
// `crew.maxParallel` at a time. Children only propose: their actions are recorded as
// `action.proposed` and never queued or executed. When every child has ended, one `join` run
// of the parent gets each child's summary, decisions, and proposals as its input; its actions
// go through policy as usual. Depth is 1: children and join runs never fan out.

/// The children and join run of a crew.
public struct CrewOutcome: Sendable, Hashable {
    /// Child runs, in delegation order.
    public var children: [RunOutcome]
    // An array, because a struct cannot hold its containing type directly.
    private var joined: [RunOutcome]
    /// The join run.
    public var join: RunOutcome { joined[0] }

    init(children: [RunOutcome], join: RunOutcome) {
        self.children = children
        joined = [join]
    }
}

/// One child's part of the join run's input.
struct CrewChildReport: Codable, Hashable {
    var delegation: String
    var title: String
    var run: RunID
    var status: String
    var summary: String?
    var decisions: [RunResult.Decision]
    var actions: [RunResult.Action]
}

extension RunRequest {
    /// True for a crew child (it has a parent and is not the join).
    var isCrewChild: Bool { parent != nil && input.kind != .join }

    /// True when this run's delegations become a crew.
    var fansOut: Bool { parent == nil && input.kind != .join && mode == .live }
}

extension RunEngine {
    /// Runs the children of `parent` and then its join run.
    func runCrew(
        _ delegations: [RunResult.Delegation], parent: RunID, request: RunRequest,
        charter: Charter
    ) async throws -> CrewOutcome {
        let width = max(1, charter.crew.maxParallel)
        let children = try await withThrowingTaskGroup(of: (Int, RunOutcome).self) { group in
            var results: [RunOutcome?] = Array(repeating: nil, count: delegations.count)
            var next = 0
            func launch(_ index: Int) {
                let child = RunRequest(
                    steward: request.steward,
                    input: RunInput(kind: request.input.kind, text: delegations[index].input),
                    mode: .live, actor: .system, parent: parent, charter: request.charter)
                group.addTask { (index, try await self.run(child)) }
            }
            while next < min(width, delegations.count) {
                launch(next)
                next += 1
            }
            while let (index, outcome) = try await group.next() {
                results[index] = outcome
                if next < delegations.count {
                    launch(next)
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
        let reports = zip(delegations, children).map { delegation, child in
            CrewChildReport(
                delegation: delegation.id, title: delegation.title, run: child.run,
                status: Self.status(child.phase), summary: child.result?.summary,
                decisions: child.result?.decisions ?? [], actions: child.result?.actions ?? [])
        }
        let text = String(
            decoding: try CanonicalJSON.encode(["children": reports]), as: UTF8.self)
        let join = RunRequest(
            steward: request.steward, input: RunInput(kind: .join, text: text), mode: .live,
            actor: .system, parent: parent, charter: request.charter)
        return CrewOutcome(children: children, join: try await run(join))
    }

    static func status(_ phase: RunPhase) -> String {
        switch phase {
        case .finished(let end): end.rawValue
        case .failed(let reason): "failed:\(reason.rawValue)"
        default: "unknown"
        }
    }
}
