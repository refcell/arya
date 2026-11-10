import AryaDesign
import Foundation

/// The steward's current plan: the newest `plan.updated` and what changed since the one
/// before it.
struct OutcomePlan: Hashable, Sendable {
    enum StepStatus: String, Hashable, Sendable {
        /// `blocked` waits on a person (an approval or an answer); `failed` is a real failure.
        case todo, doing, done, dropped, blocked, failed

        /// A compact mark for the checklist; the word is spoken to assistive tech. Waiting on a
        /// person uses the same clock as pending approvals.
        var mark: String {
            switch self {
            case .todo: "○"
            case .doing: "◐"
            case .done: "✓"
            case .blocked: "◷"
            case .dropped, .failed: "✕"
            }
        }

        /// How the step is spoken and labeled.
        var word: String {
            switch self {
            case .todo: "to do"
            case .doing: "in progress"
            case .done: "done"
            case .blocked: "waiting on you"
            case .dropped: "dropped"
            case .failed: "failed"
            }
        }
    }

    struct Step: Hashable, Sendable, Identifiable {
        var id: String
        var title: String
        var status: StepStatus
        /// Why this step exists or changed, if the steward said.
        var note: String?
    }

    var steps: [Step]
    /// Why the steward changed the plan last time.
    var reason: String?
    var updated: Date
    var run: String?
    /// Step titles added or dropped compared with the previous plan.
    var added: [String]
    var removed: [String]

    var doneCount: Int { steps.filter { $0.status == .done }.count }
    var activeCount: Int { steps.filter { $0.status != .dropped }.count }

    /// The newest plan, from the runtime's `plan.updated` `{items: [{id, text, status,
    /// rationale?}], reason?}` (`steps` with `title` and `note` also read, for older fixtures).
    static func build(events: [FeatureEvent], steward: String) -> OutcomePlan? {
        let plans = events.filter { $0.steward == steward && $0.type == "plan.updated" }
        guard let latest = plans.last else { return nil }
        let steps = parse(latest.payload)
        let previous = plans.dropLast().last.map { parse($0.payload) } ?? []
        let before = Set(previous.map(\.title))
        let now = Set(steps.map(\.title))
        return OutcomePlan(
            steps: steps, reason: latest.payload["reason"]?.string, updated: latest.at,
            run: latest.run,
            added: previous.isEmpty ? [] : steps.map(\.title).filter { !before.contains($0) },
            removed: previous.map(\.title).filter { !now.contains($0) })
    }

    /// Steps in the adapter protocol's shape (`text`, `rationale`, `pending | in_progress |
    /// done | skipped | blocked`) or the app's (`title`, `note`, `todo | doing | ...`).
    private static func parse(_ payload: FeatureJSON) -> [Step] {
        (payload["items"]?.array ?? payload["steps"]?.array ?? []).enumerated().compactMap {
            index, step in
            guard let title = step["text"]?.string ?? step["title"]?.string else { return nil }
            return Step(
                id: step["id"]?.string ?? "s\(index + 1)", title: title,
                status: status(step["status"]?.string),
                note: step["rationale"]?.string ?? step["note"]?.string)
        }
    }

    static func status(_ word: String?) -> StepStatus {
        switch word {
        case "pending": .todo
        case "in_progress": .doing
        case "skipped": .dropped
        case "waiting": .blocked
        case "error": .failed
        default: word.flatMap(StepStatus.init(rawValue:)) ?? .todo
        }
    }
}

/// One thing the steward did or proposed, and why.
struct OutcomeActivity: Hashable, Sendable, Identifiable {
    enum State: String, Hashable, Sendable {
        case executed, failed, rejected, waiting, proposed

        /// The one-character mark the Recent list leads with.
        var mark: String {
            switch self {
            case .executed: "✓"
            case .failed, .rejected: "✕"
            case .waiting: "◷"
            case .proposed: "○"
            }
        }

        var status: AryaStatus {
            switch self {
            case .executed: .executed
            case .failed: .failed
            case .rejected: .denied
            case .waiting: .waiting
            case .proposed: .idle
            }
        }
    }

    var run: String
    var action: String
    var kind: String
    var target: String?
    var reason: String
    var policy: AryaPolicy?
    /// `low`, `medium`, or `high` when the runtime recorded one.
    var risk: String?
    var state: State
    var at: Date
    var seq: Int

    var id: String { "\(run)/\(action)" }
}

/// Builds the activity feed: every action from live runs (rehearsals left out), newest first.
enum OutcomeActivityFeed {
    static func build(events: [FeatureEvent], steward: String) -> [OutcomeActivity] {
        let names = OutcomePeople.names(events: events, steward: steward)
        return build(mine: events.filter { $0.steward == steward }).map {
            var item = $0
            item.target = item.target.map { names[$0] ?? $0 }
            return item
        }
    }

    private static func build(mine: [FeatureEvent]) -> [OutcomeActivity] {
        let rehearsals = OutcomeRuns.rehearsalRuns(mine)
        var items: [String: OutcomeActivity] = [:]
        var order: [String] = []
        for event in mine {
            guard let run = event.run, !rehearsals.contains(run) else { continue }
            if event.type == "action.proposed", let item = proposed(event, run: run) {
                if items[item.id] == nil { order.append(item.id) }
                items[item.id] = item
            } else if let state = settled(event.type),
                let action = event.payload["action"]?.string
            {
                items["\(run)/\(action)"]?.state = state
            } else if event.type == "approval.requested",
                let action = event.payload["action"]?["id"]?.string
            {
                let id = "\(run)/\(action)"
                if items[id]?.state == .proposed { items[id]?.state = .waiting }
            }
        }
        let recorded = recordedActions(mine)
        return order.reversed().compactMap { id in
            guard var item = items[id] else { return nil }
            let action = recorded[item.run]?[item.action]
            item.risk = item.risk ?? action?["risk"]?.string
            if let why = action?["why"]?.string, !why.isEmpty { item.reason = why }
            return item
        }
    }

    /// Actions as each run reported them in its recorded `run/result` (in
    /// `run.adapter.event`), by run and action id; they carry the `risk` and `why` the
    /// runtime does not fold into `action.proposed` yet.
    static func recordedActions(_ events: [FeatureEvent]) -> [String: [String: FeatureJSON]] {
        var out: [String: [String: FeatureJSON]] = [:]
        for event in events where event.type == "run.adapter.event" {
            guard let run = event.run, let message = event.payload["message"],
                message["method"]?.string == "run/result",
                let actions = message["params"]?["result"]?["actions"]?.array
            else { continue }
            for action in actions {
                if let id = action["id"]?.string { out[run, default: [:]][id] = action }
            }
        }
        return out
    }

    private static func settled(_ type: String) -> OutcomeActivity.State? {
        switch type {
        case "action.executed": .executed
        case "action.failed": .failed
        case "action.rejected": .rejected
        default: nil
        }
    }

    private static func proposed(_ event: FeatureEvent, run: String) -> OutcomeActivity? {
        let action = event.payload["action"]
        guard let id = action?["id"]?.string, let kind = action?["kind"]?.string else {
            return nil
        }
        let disposition = event.payload["disposition"]?.string
        let reason =
            action?["why"]?.string ?? action?["rationale"]?.string
            ?? event.payload["reason"]?.string ?? ""
        return OutcomeActivity(
            run: run, action: id, kind: kind, target: action?["target"]?.string,
            reason: reason, policy: disposition.flatMap(AryaPolicy.init(rawValue:)),
            risk: event.payload["risk"]?.string ?? action?["risk"]?.string,
            state: disposition == "deny" ? .rejected : .proposed, at: event.at, seq: event.seq)
    }
}

/// Run helpers shared by the Outcome views.
enum OutcomeRuns {
    /// Runs that belong to rehearsals.
    static func rehearsalRuns(_ events: [FeatureEvent]) -> Set<String> {
        Set(events.filter { $0.type == "run.started" && isRehearsal($0.payload) }.compactMap(\.run))
    }

    /// Whether a `run.started` payload is a rehearsal case run: the runtime records the
    /// rehearsal id and the case (`rehearsal: "reh_…"`, `case`, `input.kind: case`); older
    /// fixtures write `rehearsal: true` or trigger `case`.
    static func isRehearsal(_ payload: FeatureJSON) -> Bool {
        if let flag = payload["rehearsal"]?.bool { return flag }
        return payload["rehearsal"]?.string != nil || payload["case"] != nil
            || payload["trigger"]?.string == "case" || payload["input"]?["kind"]?.string == "case"
    }
}

/// What a person needs when they come back to a steward: the goal, how the last run ended,
/// what happened since they last looked, and what still waits on them.
struct OutcomeRecap: Hashable, Sendable {
    struct LastRun: Hashable, Sendable {
        var run: String
        var status: AryaStatus
        var summary: String
        var at: Date
    }

    struct Pending: Hashable, Sendable, Identifiable {
        var approval: String
        var run: String?
        var kind: String
        var target: String?
        var rationale: String

        var id: String { approval }
    }

    var goal: String
    var lastRun: LastRun?
    /// Runs that ended and actions taken after the person's last visit.
    var runsSince: Int
    var actionsSince: [OutcomeActivity]
    var pending: [Pending]
    var questions: Int
    var failedActions: Int
    var openProposals: Int

    var unresolvedCount: Int { pending.count + questions + failedActions + openProposals }
    /// When the newest news happened: the last run or the newest action since the visit.
    var newestAt: Date? { ([lastRun?.at] + actionsSince.map(\.at)).compactMap { $0 }.max() }

    /// `lastSeen` is the newest ledger seq the person saw; nil means never.
    static func build(
        events: [FeatureEvent], steward: String, activity: [OutcomeActivity], lastSeen: Int?
    ) -> OutcomeRecap {
        let mine = events.filter { $0.steward == steward }
        let rehearsals = OutcomeRuns.rehearsalRuns(mine)
        let ends = mine.filter {
            ["run.finished", "run.failed"].contains($0.type)
                && !rehearsals.contains($0.run ?? "")
        }
        let last = ends.last.map { end in
            LastRun(
                run: end.run ?? "", status: end.type == "run.failed" ? .failed : .done,
                summary: end.payload["summary"]?.string ?? end.payload["error"]?.string ?? "",
                at: end.at)
        }
        let since = lastSeen ?? 0
        let overview = StewardOverview.build(events: events, steward: steward)
        return OutcomeRecap(
            goal: LiveCharter.find(events: events, steward: steward)?.charter["outcome"]?.string
                ?? "",
            lastRun: last, runsSince: ends.filter { $0.seq > since }.count,
            actionsSince: activity.filter { $0.seq > since && $0.state == .executed },
            pending: pending(mine), questions: overview.waitingQuestions,
            failedActions: activity.filter { $0.state == .failed }.count,
            openProposals: overview.openProposals)
    }

    private static func pending(_ mine: [FeatureEvent]) -> [Pending] {
        let decided = Set(
            mine.filter {
                ["approval.granted", "approval.denied", "approval.expired"].contains($0.type)
            }
            .compactMap { $0.payload["approval"]?.string })
        return mine.compactMap { event in
            guard event.type == "approval.requested",
                let id = event.payload["approval"]?.string, !decided.contains(id),
                event.payload["to"]?.string?.hasPrefix("person:") != true,
                let action = event.payload["action"]
            else { return nil }
            return Pending(
                approval: id, run: event.run, kind: action["kind"]?.string ?? "action",
                target: action["target"]?.string,
                rationale: action["rationale"]?.string ?? "")
        }
    }
}

/// People by name: "person:sam" reads "Sam", from the charter's person bindings.
enum OutcomePeople {
    static func names(events: [FeatureEvent], steward: String) -> [String: String] {
        var out: [String: String] = [:]
        let charter = LiveCharter.find(events: events, steward: steward)?.charter
        for binding in charter?["bindings"]?.array ?? [] where binding["kind"]?.string == "person" {
            guard let id = binding["id"]?.string else { continue }
            out[id] = binding["name"]?.string ?? name(id)
        }
        for event in events where event.steward == steward {
            for key in ["from", "to", "person"] {
                if let id = event.payload[key]?.string, id.hasPrefix("person:"), out[id] == nil {
                    out[id] = name(id)
                }
            }
        }
        return out
    }

    /// Workspace text with every person id named: "Knows person:ana" → "Knows Ana".
    static func humanize(_ text: String, names: [String: String]) -> String {
        guard text.contains("person:") else { return text }
        var out = ""
        var rest = Substring(text)
        while let range = rest.range(of: "person:") {
            out += rest[..<range.lowerBound]
            let tail = rest[range.upperBound...]
            let slug = tail.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            let id = "person:" + slug
            out += names[id] ?? name(id)
            rest = tail.dropFirst(slug.count)
        }
        return out + rest
    }

    /// "person:priya" → "Priya".
    static func name(_ id: String) -> String {
        id.hasPrefix("person:") ? String(id.dropFirst("person:".count)).capitalized : id
    }
}
