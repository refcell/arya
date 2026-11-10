import AryaAdapters
import AryaCore
import AryaLedger

// Re-planning (decision 0046). When an action a steward proposed does not happen (it failed,
// or a person denied it or let it expire), the steward hears about it in a `replan` run of its
// own (`parent` = the run that hit the setback), whose instructions carry the current plan, so
// it can revise the plan (`plan.updated` with a reason) and propose different actions. A chain
// of re-plans from one run is bounded by `limits.maxReplans`; past it, `run.replan.refused` is
// recorded on the run that hit the setback. Only active stewards re-plan, and never from a
// rehearsal, a crew child (children only propose), or a replay.

/// An action that did not happen.
public struct Setback: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Executed and failed.
        case failed
        /// A person denied it.
        case denied
        /// Its approval expired.
        case expired
    }

    public var kind: Kind
    public var action: ProposedAction
    /// The executor's error, or the person's note.
    public var detail: String?
    /// The approval that held it.
    public var approval: ApprovalID?

    /// Creates a setback.
    public init(
        kind: Kind, action: ProposedAction, detail: String? = nil, approval: ApprovalID? = nil
    ) {
        self.kind = kind
        self.action = action
        self.detail = detail
        self.approval = approval
    }

    /// The setback of an auto action that failed, if it did.
    init?(_ disposal: ActionDisposal) {
        guard case .failed(let error, _)? = disposal.outcome else { return nil }
        self.init(kind: .failed, action: disposal.action, detail: error)
    }

    /// The setback of a decided approval: denied, expired, or granted and then failed
    /// (`executed`). Nil for questions and for actions that happened.
    public init?(_ record: ApprovalRecord, executed: ExecutionOutcome? = nil) {
        guard case .action(let action) = record.subject else { return nil }
        switch (record.status, executed) {
        case (.denied, _): self.init(kind: .denied, action: action, detail: record.note)
        case (.expired, _): self.init(kind: .expired, action: action)
        case (.granted, .failed(let error, _)?):
            self.init(kind: .failed, action: action, detail: error)
        default: return nil
        }
        approval = record.id
    }

    /// One line a steward reads.
    var line: String {
        var text = "- \(action.kind)"
        if let target = action.target { text += " \(target)" }
        text += " (\(action.id)): \(kind.rawValue)"
        if let detail, !detail.isEmpty { text += ": \(detail)" }
        return text
    }
}

/// `run.replan.refused`: setbacks of the run that no re-plan run will see, because its chain
/// used `limits.maxReplans` (actor: system, run: the run that hit them).
public struct ReplanRefused: EventPayload {
    public static let type = EventType("run.replan.refused")
    public var setbacks: [Setback]
    /// For example `max_replans: 2`.
    public var reason: String

    enum CodingKeys: String, CodingKey { case setbacks, reason }
}

enum Replans {
    /// The run text of a re-plan.
    static func text(_ setbacks: [Setback]) -> String {
        (["Some actions you proposed did not happen:"] + setbacks.map(\.line) + [
            "Revise your plan toward the outcome and return the whole plan with a rationale for "
                + "what changed. Propose actions only if they still serve the outcome."
        ]).joined(separator: "\n")
    }

    /// The run a re-plan chain started from.
    static func origin(of run: RunID, in book: RunBook) -> RunID {
        var id = run
        while let record = book.records[id], record.trigger == RunInputKind.replan.rawValue,
            let parent = record.parent
        {
            id = parent
        }
        return id
    }
}

extension RunEngine {
    /// Starts a re-plan run of `steward` for `setbacks` of `run` and waits for it, unless the
    /// steward is not active or the chain from `run`'s origin used `limits.maxReplans` (then
    /// records `run.replan.refused`). Returns the re-plan's outcome, or nil when none started.
    @discardableResult
    public func replan(after run: RunID, steward: StewardID, setbacks: [Setback]) async throws
        -> RunOutcome?
    {
        guard !setbacks.isEmpty else { return nil }
        let events = try await sink.events(from: 1)
        guard let record = try StewardBook(events).records[steward], record.status == .active
        else { return nil }
        let book = try RunBook(events)
        // A report run's setback is a report not sent; it never starts a re-plan (0050).
        if book.records[run]?.trigger == RunTriggerKind.report.rawValue { return nil }
        let origin = Replans.origin(of: run, in: book)
        let used = book.all.filter {
            $0.trigger == RunInputKind.replan.rawValue
                && Replans.origin(of: $0.id, in: book) == origin
        }.count
        let limit = record.charter.limits.maxReplans
        guard used < limit else {
            _ = try await sink.append(
                RuntimeEventDraft(
                    type: ReplanRefused.type.rawValue, steward: steward, run: run, actor: .system,
                    payload: try Payload.encode(
                        ReplanRefused(setbacks: setbacks, reason: "max_replans: \(limit)"))))
            return nil
        }
        let attachments = try setbacks.map { try CanonicalJSON.jsonValue($0) }
        let input = RunInput(kind: .replan, text: Replans.text(setbacks), attachments: attachments)
        return try await self.run(
            RunRequest(steward: steward, input: input, mode: .live, actor: .system, parent: run))
    }

    /// The re-plan after a live run whose auto actions failed, if it may re-plan.
    func replanAfterFailures(_ outcome: RunOutcome, _ request: RunRequest) async throws
        -> RunOutcome?
    {
        guard request.replanning, request.mode == .live, request.rehearsal == nil,
            !request.isCrewChild
        else { return nil }
        let setbacks = outcome.disposals.compactMap(Setback.init)
        return try await replan(after: outcome.run, steward: request.steward, setbacks: setbacks)
    }
}
