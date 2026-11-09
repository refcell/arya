import AryaAdapters
import AryaCore
import AryaLedger

// Crews (ARCHITECTURE.md "Crews", decision 0043). After a live top-level run finishes with
// `delegations`, each delegation becomes a child run (`parent` = that run) under the parent's
// charter, at most `crew.maxParallel` at a time. A delegation may ask for another adapter
// (only one the charter's `crew.adapters` lists), a lower effort, and smaller limits; nothing
// a child gets exceeds the parent's, and the policy and sandbox are the parent's. Each
// delegation records `run.delegated` on the parent run, with the child's id or why it was
// refused. Children only propose: their actions are recorded as `action.proposed` and never
// queued or executed. When every child has ended, one `join` run of the parent gets each
// child's summary, decisions, and proposals as its input; its actions go through policy as
// usual. Depth is 1: children and join runs never fan out.

/// What a crew child runs with instead of the charter's adapter, effort, and limits. Applying
/// it never raises anything above the charter's.
public struct CrewBudget: Sendable, Hashable {
    public var adapter: String?
    public var effort: Effort?
    public var limits: Limits?

    /// Creates a budget.
    public init(adapter: String? = nil, effort: Effort? = nil, limits: Limits? = nil) {
        self.adapter = adapter
        self.effort = effort
        self.limits = limits
    }

    /// `charter` with this budget: the adapter when it is the charter's own or listed in
    /// `crew.adapters` (else the charter's), the lower effort, and each limit capped at the
    /// charter's and at least 1.
    public func applied(to charter: Charter) -> Charter {
        var out = charter
        if let adapter, Self.allows(adapter, charter) { out.adapter = adapter }
        if let effort, Self.rank(effort) < Self.rank(charter.effort) { out.effort = effort }
        if let limits {
            let cap = charter.limits
            out.limits = Limits(
                maxTurns: max(1, min(limits.maxTurns, cap.maxTurns)),
                timeoutSeconds: max(1, min(limits.timeoutSeconds, cap.timeoutSeconds)),
                maxCostMicros: max(1, min(limits.maxCostMicros, cap.maxCostMicros)))
        }
        return out
    }

    /// The budget a delegation asks for, or why it is refused (`adapter_not_allowed:<name>`,
    /// `unknown_effort:<value>`).
    static func requested(by delegation: RunResult.Delegation, charter: Charter)
        -> Result<CrewBudget, CrewRefusal>
    {
        if let adapter = delegation.adapter, !allows(adapter, charter) {
            return .failure(CrewRefusal("adapter_not_allowed:\(adapter)"))
        }
        var effort: Effort?
        if let raw = delegation.effort {
            guard let parsed = Effort(rawValue: raw) else {
                return .failure(CrewRefusal("unknown_effort:\(raw)"))
            }
            effort = parsed
        }
        let cap = charter.limits
        let limits = delegation.limits.map {
            Limits(
                maxTurns: $0.maxTurns ?? cap.maxTurns,
                timeoutSeconds: $0.timeoutSeconds ?? cap.timeoutSeconds,
                maxCostMicros: $0.maxCostMicros ?? cap.maxCostMicros)
        }
        return .success(CrewBudget(adapter: delegation.adapter, effort: effort, limits: limits))
    }

    static func allows(_ adapter: String, _ charter: Charter) -> Bool {
        adapter == charter.adapter || charter.crew.adapters.contains(adapter)
    }

    private static func rank(_ effort: Effort) -> Int {
        switch effort {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

/// Why a delegation did not become a child run.
struct CrewRefusal: Error, Hashable {
    var reason: String
    init(_ reason: String) { self.reason = reason }
}

/// `run.delegated`: a delegation of the parent run (actor: the steward, run: the parent). A
/// started child has `child`, `adapter`, `effort`, and `limits` as it will run with them; a
/// refused one has `refused`.
public struct RunDelegated: EventPayload {
    public static let type = EventType("run.delegated")
    public var delegation: String
    public var title: String
    public var child: RunID?
    public var adapter: String?
    public var effort: Effort?
    public var limits: Limits?
    public var refused: String?

    enum CodingKeys: String, CodingKey {
        case delegation, title, child, adapter, effort, limits, refused
    }
}

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
    var run: RunID?
    var status: String
    var summary: String?
    var decisions: [RunResult.Decision]
    var actions: [RunResult.Action]
}

extension RunRequest {
    /// True for a crew child (it has a parent and is not the join).
    var isCrewChild: Bool { parent != nil && input.kind != .join }

    /// True when this run's delegations become a crew.
    var fansOut: Bool {
        parent == nil && input.kind != .join && mode == .live && crewPolicy == .run
    }

    /// A child or join run of this request's crew, keeping its mode, rehearsal tag, and
    /// candidate routine.
    func crewMember(_ input: RunInput, parent: RunID) -> RunRequest {
        var member = RunRequest(
            steward: steward, input: input, mode: mode, actor: .system, parent: parent,
            charter: charter, rehearsal: rehearsal)
        member.routine = routine
        return member
    }
}

extension RunEngine {
    /// Runs the children of `parent` and then its join run. Children and the join keep the
    /// request's mode, rehearsal tag, and candidate routine, so a caller (eval) can run a
    /// rehearsal's crew in rehearsal mode; `run` fans out only live runs on its own.
    public func runCrew(
        _ delegations: [RunResult.Delegation], parent: RunID, request: RunRequest,
        charter: Charter
    ) async throws -> CrewOutcome {
        let width = max(1, charter.crew.maxParallel)
        var refused: [Int: String] = [:]
        var launches: [(Int, RunRequest)] = []
        for (index, delegation) in delegations.enumerated() {
            switch CrewBudget.requested(by: delegation, charter: charter) {
            case .failure(let refusal):
                refused[index] = refusal.reason
                try await recordDelegated(
                    RunDelegated(
                        delegation: delegation.id, title: delegation.title,
                        refused: refusal.reason), request.steward, parent)
            case .success(let budget):
                var child = request.crewMember(
                    RunInput(kind: request.input.kind, text: delegation.input), parent: parent)
                child.crew = budget
                child.id = ambient.newID(RunID.self)
                launches.append((index, child))
            }
        }
        var results: [Int: RunOutcome] = [:]
        try await withThrowingTaskGroup(of: (Int, RunOutcome).self) { group in
            var next = 0
            func launch() async throws {
                let (index, child) = launches[next]
                next += 1
                let applied = child.crew.map { $0.applied(to: charter) } ?? charter
                try await recordDelegated(
                    RunDelegated(
                        delegation: delegations[index].id, title: delegations[index].title,
                        child: child.id, adapter: applied.adapter, effort: applied.effort,
                        limits: applied.limits), request.steward, parent)
                group.addTask { (index, try await self.run(child)) }
            }
            while next < min(width, launches.count) { try await launch() }
            while let (index, outcome) = try await group.next() {
                results[index] = outcome
                if next < launches.count { try await launch() }
            }
        }
        let reports = delegations.enumerated().map { index, delegation in
            let child = results[index]
            return CrewChildReport(
                delegation: delegation.id, title: delegation.title, run: child?.run,
                status: refused[index].map { "refused:\($0)" }
                    ?? child.map { Self.status($0.phase) } ?? "unknown",
                summary: child?.result?.summary, decisions: child?.result?.decisions ?? [],
                actions: child?.result?.actions ?? [])
        }
        let text = String(
            decoding: try CanonicalJSON.encode(["children": reports]), as: UTF8.self)
        let join = request.crewMember(RunInput(kind: .join, text: text), parent: parent)
        let children = results.keys.sorted().compactMap { results[$0] }
        return CrewOutcome(children: children, join: try await run(join))
    }

    private func recordDelegated(_ payload: RunDelegated, _ steward: StewardID, _ parent: RunID)
        async throws
    {
        _ = try await sink.append(
            RuntimeEventDraft(
                type: RunDelegated.type.rawValue, steward: steward, run: parent,
                actor: .steward(steward), payload: try Payload.encode(payload)))
    }

    static func status(_ phase: RunPhase) -> String {
        switch phase {
        case .finished(let end): end.rawValue
        case .failed(let reason): "failed:\(reason.rawValue)"
        default: "unknown"
        }
    }
}
