import AryaCore
import AryaEval
import AryaLedger
import AryaRuntime
import Foundation

// Outcome-first read models for the app: where a steward stands against its outcome, its
// plan, a recap since the person last looked, and a human-readable activity feed. Plus
// structured steward creation, and binding and people read models.

/// The charter's trigger type (`StewardDraft.Trigger` shadows the name inside the draft).
typealias CharterTrigger = Trigger

/// Where a steward stands against its outcome.
public struct OutcomeSummary: Sendable, Hashable, Codable {
    /// Against the target, in the metric's better direction.
    public enum Status: String, Sendable, Hashable, Codable {
        /// The latest window meets the target.
        case onTrack = "on_track"
        /// The latest window misses the target.
        case offTrack = "off_track"
        /// The charter sets no target.
        case noTarget = "no_target"
        /// No window has a value yet.
        case noData = "no_data"
    }

    /// One window of the trend.
    public struct Point: Sendable, Hashable, Codable {
        public var start: Date
        /// The window's mean, or `nil` when nothing was recorded in it.
        public var value: Double?
    }

    public var steward: String
    /// The success definition: the charter's outcome sentence.
    public var outcome: String
    /// KPI name, unit, and which way is better (`up` or `down`).
    public var metric: String
    public var unit: String
    public var direction: String
    public var target: Double?
    /// The newest window with a value.
    public var current: Double?
    /// The last windows, oldest first, for a sparkline.
    public var trend: [Point]
    public var windowSeconds: Int
    public var status: Status
}

/// A steward's current plan.
public struct Plan: Sendable, Hashable, Codable {
    public struct Item: Sendable, Hashable, Codable {
        public var id: String
        public var text: String
        /// `pending`, `in_progress`, `done`, `skipped`, or `blocked`.
        public var status: String
        /// Why the step stands where it does, when the steward said.
        public var reason: String?
        public var updatedAt: Date?
    }

    public var steward: String
    public var items: [Item]
    /// When the plan last changed and why, if it ever did.
    public var updatedAt: Date?
    public var reason: String?
    /// The run that changed it last.
    public var run: String?
}

/// One thing a steward did, readable by a person, linking to its run and event.
public struct ActivityItem: Sendable, Hashable, Codable {
    /// `decision`, `action`, `approval`, `run`, `memory`, `routine`, or `charter`.
    public var kind: String
    /// What happened, for example "Labeled inbox:MSG-9 (executed)".
    public var text: String
    /// Why, when the steward or person gave a reason.
    public var reason: String?
    /// True when it needs attention (a failure or a pending approval).
    public var unresolved: Bool
    public var at: Date
    public var seq: Int
    public var event: String
    public var run: String?
}

/// What a person needs on opening a steward: goal, outcome, what happened since `since`,
/// what is unresolved, and what waits on them.
public struct Recap: Sendable, Hashable, Codable {
    public var steward: String
    public var goal: String
    public var outcome: OutcomeSummary
    /// The ledger `seq` the recap starts after, and the newest one it covers.
    public var since: Int
    public var through: Int
    /// Actions and decisions since `since`, oldest first.
    public var activity: [ActivityItem]
    /// Failed actions and runs since `since`.
    public var unresolved: [ActivityItem]
    public var pendingApprovals: [ApprovalSummary]
}

/// A charter binding.
public struct BindingSummary: Sendable, Hashable, Codable {
    public var id: String
    /// `mcp` or `person`.
    public var kind: String
    public var command: String?
    public var read: [String]
    public var actions: [String]
    /// For people: how to reach them, for example `inbox`.
    public var channel: String?
}

/// A person a steward works with (a person binding).
public struct PersonSummary: Sendable, Hashable, Codable {
    public var id: String
    public var channel: String?
    /// True when their messages start runs (a `message` trigger for them or for anyone).
    public var takesMessages: Bool
    /// Approvals and questions addressed to them that are still pending.
    public var pending: Int
}

/// A new steward from structured fields (the app's New steward flow).
public struct StewardDraft: Sendable, Hashable, Codable {
    public struct Binding: Sendable, Hashable, Codable {
        public var id: String
        /// `mcp` or `person`.
        public var kind: String
        public var command: String?
        public var args: [String]
        public var read: [String]
        public var actions: [String]
        public var channel: String?

        public init(
            id: String, kind: String, command: String? = nil, args: [String] = [],
            read: [String] = [], actions: [String] = [], channel: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.command = command
            self.args = args
            self.read = read
            self.actions = actions
            self.channel = channel
        }
    }

    public struct Rule: Sendable, Hashable, Codable {
        public var action: String
        public var binding: String?
        /// `auto`, `ask`, or `deny`.
        public var decision: String
        /// The guardrail in a person's words, shown where the rule holds an action.
        public var note: String?

        public init(action: String, binding: String? = nil, decision: String, note: String? = nil) {
            self.action = action
            self.binding = binding
            self.decision = decision
            self.note = note
        }
    }

    public struct Trigger: Sendable, Hashable, Codable {
        /// `manual`, `interval`, or `message`.
        public var kind: String
        public var everySeconds: Int?
        public var from: String?

        public init(kind: String, everySeconds: Int? = nil, from: String? = nil) {
            self.kind = kind
            self.everySeconds = everySeconds
            self.from = from
        }
    }

    /// Steward id; derived from the name (`st_<slug>`) when nil.
    public var id: String?
    public var name: String
    public var outcome: String
    public var metric: String
    public var unit: String
    /// `up` or `down`.
    public var direction: String
    public var target: Double?
    public var guardrails: [String]
    /// Autonomy: the default for actions no rule names, and rules.
    public var autonomy: String
    public var rules: [Rule]
    public var bindings: [Binding]
    public var effort: String
    public var triggers: [Trigger]
    /// Adapter profile name in `adapters.json`.
    public var adapter: String
    /// How far the steward acts on its own: `observe`, `suggest`, `act_low`, or `act_medium`;
    /// nil for none (rules and `autonomy` alone decide).
    public var level: String?
    /// Who answers for the outcome, and the department it serves.
    public var owner: String?
    public var department: String?

    public init(
        id: String? = nil, name: String, outcome: String, metric: String, unit: String,
        direction: String = "up", target: Double? = nil, guardrails: [String] = [],
        autonomy: String = "ask", rules: [Rule] = [], bindings: [Binding] = [],
        effort: String = "medium", triggers: [Trigger] = [Trigger(kind: "manual")],
        adapter: String, level: String? = nil, owner: String? = nil, department: String? = nil
    ) {
        self.level = level
        self.owner = owner
        self.department = department
        self.id = id
        self.name = name
        self.outcome = outcome
        self.metric = metric
        self.unit = unit
        self.direction = direction
        self.target = target
        self.guardrails = guardrails
        self.autonomy = autonomy
        self.rules = rules
        self.bindings = bindings
        self.effort = effort
        self.triggers = triggers
        self.adapter = adapter
    }
}

extension Workspace {
    // MARK: Outcome

    /// Where a steward stands: its outcome, KPI, target, the last `windows` windows of
    /// `windowSeconds` (UTC days by default), and the status of the newest value.
    public func outcome(steward: String, windows: Int = 14, windowSeconds: Int = 86_400)
        async throws -> OutcomeSummary
    {
        let record = try await existing(steward)
        let series = try await metrics(steward: steward, windowSeconds: windowSeconds)
        let metric = record.charter.metric
        let trend = series.windows.suffix(max(1, windows)).map {
            OutcomeSummary.Point(start: $0.start, value: $0.means[metric.name])
        }
        let current = trend.last { $0.value != nil }?.value
        return OutcomeSummary(
            steward: record.id.rawValue, outcome: record.charter.outcome, metric: metric.name,
            unit: metric.unit, direction: metric.direction.rawValue, target: metric.target,
            current: current, trend: Array(trend), windowSeconds: series.windowSeconds,
            status: Self.status(current: current, metric: metric))
    }

    static func status(current: Double?, metric: Metric) -> OutcomeSummary.Status {
        guard let target = metric.target else { return .noTarget }
        guard let current else { return .noData }
        let met = metric.direction == .down ? current <= target : current >= target
        return met ? .onTrack : .offTrack
    }

    // MARK: Risk

    /// The risk of an action `kind` through `binding` as the runtime resolves it (decision 0037):
    /// the steward's charter `policy.risk`, else the kind's default (`Risk.defaults`). With no
    /// `steward` (a steward being drafted), the defaults alone.
    public func risk(kind: String, binding: String? = nil, steward: String? = nil) async throws
        -> String
    {
        var policy = Policy()
        if let steward { policy = try await existing(steward).charter.policy }
        return policy.risk(ofAction: kind, binding: binding).rawValue
    }

    // MARK: Plan

    /// The steward's current plan: the newest runtime `plan.updated` for it, with the run
    /// that changed it and why. Homes written before runtime recorded plans fall back to the
    /// newest live run result that carried one. No items until a run reports a plan.
    public func plan(steward: String) async throws -> Plan {
        let id = try await existing(steward).id
        if let event = try await sink.events(from: 1).last(where: {
            $0.type == PlanEventType.updated && $0.draft.steward == id
        }) {
            let body = try CanonicalJSON.decode(
                PlanUpdated.self, from: try CanonicalJSON.encode(event.payload))
            let at = event.at.date
            return Plan(
                steward: id.rawValue,
                items: body.items.map {
                    Plan.Item(
                        id: $0.id, text: $0.text, status: $0.status.rawValue, reason: $0.rationale,
                        updatedAt: at)
                },
                updatedAt: at, reason: body.reason, run: event.draft.run?.rawValue)
        }
        let live = Set(
            try await runBook().all.filter { $0.steward == id && $0.trigger != "case" }
                .map(\.id))
        guard let latest = RecordedResults(try reader.events()).latestPlan(among: live) else {
            return Plan(steward: id.rawValue, items: [], updatedAt: nil, reason: nil, run: nil)
        }
        let summary = latest.result.summary
        return Plan(
            steward: id.rawValue,
            items: latest.result.plan.map {
                Plan.Item(
                    id: $0.id, text: $0.text, status: $0.status.rawValue, reason: $0.rationale,
                    updatedAt: latest.at)
            },
            updatedAt: latest.at, reason: summary.isEmpty ? nil : summary,
            run: latest.run.rawValue)
    }

    // MARK: Activity and recap

    /// What a steward did and why, newest first, across runs: decisions, action outcomes,
    /// approvals, finished and failed runs, memory, routine, and charter changes.
    public func activity(steward: String, limit: Int = 50) async throws -> [ActivityItem] {
        let id = try await existing(steward).id
        let items = try ActivityFeed(events: try reader.events(), steward: id).items
        return Array(items.reversed().prefix(max(0, limit)))
    }

    /// A recap since the person last looked: pass the newest `seq` they saw (0 for
    /// everything). The app keeps that `seq`; the facade stores no per-person state.
    public func recap(steward: String, since seq: Int = 0) async throws -> Recap {
        let id = try await existing(steward).id
        let events = try reader.events()
        let feed = try ActivityFeed(events: events, steward: id).items.filter { $0.seq > seq }
        let pending = try await approvals().filter { $0.steward == id.rawValue }
        return Recap(
            steward: id.rawValue, goal: try await existing(steward).charter.outcome,
            outcome: try await outcome(steward: steward), since: seq,
            through: Int(events.last?.seq ?? 0),
            activity: feed.filter { $0.kind == "action" || $0.kind == "decision" },
            unresolved: feed.filter { $0.unresolved && $0.kind != "approval" },
            pendingApprovals: pending)
    }

    // MARK: Bindings and people

    /// The steward's bindings in charter order.
    public func bindings(steward: String) async throws -> [BindingSummary] {
        try await existing(steward).charter.bindings.map {
            BindingSummary(
                id: $0.id, kind: $0.kind.rawValue, command: $0.command, read: $0.read,
                actions: $0.actions, channel: $0.channel)
        }
    }

    /// The people the steward works with (its person bindings).
    public func people(steward: String) async throws -> [PersonSummary] {
        let charter = try await existing(steward).charter
        let pending = try await approvals().filter { $0.steward == charter.id.rawValue }
        return charter.bindings.filter { $0.kind == .person }.map { binding in
            let takes = charter.triggers.contains {
                if case .message(let from) = $0 { return from == nil || from == binding.id }
                return false
            }
            return PersonSummary(
                id: binding.id, channel: binding.channel, takesMessages: takes,
                pending: pending.filter { $0.to == binding.id }.count)
        }
    }

    // MARK: Structured creation

    /// Records a new steward from structured fields (`steward.created`, version 1).
    public func createSteward(_ draft: StewardDraft) async throws -> StewardSummary {
        try await createSteward(charter: try CanonicalJSON.encode(try draft.charter()))
    }
}

extension StewardDraft {
    /// The charter these fields describe; invalid values are refused with what to fix.
    func charter() throws -> Charter {
        func fail(_ text: String) -> WorkspaceError { .rejected(text) }
        let id = self.id ?? "st_" + Self.slug(name)
        guard let steward = StewardID(rawValue: id) else { throw fail("invalid steward id \(id)") }
        guard let direction = Metric.Direction(rawValue: direction) else {
            throw fail("direction must be up or down, not \(self.direction)")
        }
        guard let fallback = PolicyDecision(rawValue: autonomy) else {
            throw fail("autonomy must be auto, ask, or deny, not \(autonomy)")
        }
        guard let effort = Effort(rawValue: effort) else {
            throw fail("effort must be low, medium, or high, not \(self.effort)")
        }
        let rules = try self.rules.map { rule in
            guard let decision = PolicyDecision(rawValue: rule.decision) else {
                throw fail("rule \(rule.action): decision must be auto, ask, or deny")
            }
            return Policy.Rule(
                action: rule.action, binding: rule.binding, decision: decision, note: rule.note)
        }
        let bindings = try self.bindings.map { binding -> CharterBinding in
            switch binding.kind {
            case "person":
                var person = CharterBinding.person(binding.id, channel: binding.channel ?? "inbox")
                person.actions = binding.actions
                return person
            case "mcp":
                guard let command = binding.command else {
                    throw fail("binding \(binding.id): an mcp binding needs a command")
                }
                return .mcp(
                    binding.id, command: command, args: binding.args, read: binding.read,
                    actions: binding.actions)
            default: throw fail("binding \(binding.id): kind must be mcp or person")
            }
        }
        let triggers = try self.triggers.map { trigger -> CharterTrigger in
            switch trigger.kind {
            case "manual": return .manual
            case "message": return .message(from: trigger.from)
            case "interval":
                guard let seconds = trigger.everySeconds, seconds > 0 else {
                    throw fail("an interval trigger needs everySeconds > 0")
                }
                return .interval(everySeconds: seconds)
            default: throw fail("trigger kind must be manual, interval, or message")
            }
        }
        let autonomy = try level.flatMap { level -> Autonomy? in
            if level.isEmpty { return nil }
            guard let value = Autonomy(rawValue: level) else {
                throw fail("level must be observe, suggest, act_low, or act_medium, not \(level)")
            }
            return value
        }
        var policy = Policy(rules: rules)
        policy.default = fallback
        var charter = Charter(
            id: steward, name: name, outcome: outcome,
            metric: Metric(name: metric, unit: unit, direction: direction, target: target),
            guardrails: guardrails, bindings: bindings, triggers: triggers, policy: policy,
            adapter: adapter, effort: effort)
        charter.autonomy = autonomy
        charter.owner = owner.flatMap { $0.isEmpty ? nil : $0 }
        charter.department = department.flatMap { $0.isEmpty ? nil : $0 }
        return charter
    }

    /// The fields of `charter` a person edits; the rest (risk rules, crew, limits, scorer,
    /// gate) stay on the charter and survive `applied(to:)`.
    init(_ charter: Charter) {
        self.init(
            id: charter.id.rawValue, name: charter.name, outcome: charter.outcome,
            metric: charter.metric.name, unit: charter.metric.unit,
            direction: charter.metric.direction.rawValue, target: charter.metric.target,
            guardrails: charter.guardrails, autonomy: charter.policy.default.rawValue,
            rules: charter.policy.rules.map {
                Rule(
                    action: $0.action, binding: $0.binding, decision: $0.decision.rawValue,
                    note: $0.note)
            },
            bindings: charter.bindings.map {
                Binding(
                    id: $0.id, kind: $0.kind.rawValue, command: $0.command, args: $0.args,
                    read: $0.read, actions: $0.actions, channel: $0.channel)
            },
            effort: charter.effort.rawValue,
            triggers: charter.triggers.map {
                switch $0 {
                case .manual: Trigger(kind: "manual")
                case .interval(let seconds): Trigger(kind: "interval", everySeconds: seconds)
                case .message(let from): Trigger(kind: "message", from: from)
                }
            },
            adapter: charter.adapter, level: charter.autonomy?.rawValue, owner: charter.owner,
            department: charter.department)
    }

    /// `base` with these fields applied; fields a draft does not hold are kept from `base`.
    func applied(to base: Charter) throws -> Charter {
        let edited = try charter()
        guard edited.id == base.id else {
            throw WorkspaceError.rejected(
                "draft is for \(edited.id.rawValue), not \(base.id.rawValue)")
        }
        var out = base
        out.name = edited.name
        out.outcome = edited.outcome
        out.metric = edited.metric
        out.guardrails = edited.guardrails
        out.bindings = edited.bindings.map { binding in
            guard var kept = base.bindings.first(where: { $0.id == binding.id }) else {
                return binding
            }
            kept.kind = binding.kind
            kept.command = binding.command
            kept.args = binding.args
            kept.read = binding.read
            kept.actions = binding.actions
            kept.channel = binding.channel
            return kept
        }
        out.triggers = edited.triggers
        out.policy.rules = edited.policy.rules
        out.policy.default = edited.policy.default
        out.adapter = edited.adapter
        out.effort = edited.effort
        out.autonomy = edited.autonomy
        out.owner = edited.owner
        out.department = edited.department
        return out
    }

    /// Lowercase letters and digits, other runs as `_`, for example "Inbox triage" →
    /// `inbox_triage`.
    static func slug(_ name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != "_" {
                out.append("_")
            }
        }
        while out.last == "_" { out.removeLast() }
        return out.isEmpty ? "steward" : out
    }
}

/// Builds activity items from one steward's ledger events, oldest first.
struct ActivityFeed {
    private(set) var items: [ActivityItem] = []
    private var proposed: [String: ProposedAction] = [:]

    init(events: [Event], steward: StewardID) throws {
        for event in events where event.steward == steward { try apply(event) }
    }

    private mutating func add(
        _ event: Event, _ kind: String, _ text: String, reason: String? = nil,
        unresolved: Bool = false
    ) {
        items.append(
            ActivityItem(
                kind: kind, text: text, reason: reason, unresolved: unresolved,
                at: event.at.date, seq: Int(event.seq), event: event.id.rawValue,
                run: event.run?.rawValue))
    }

    private func key(_ event: Event, _ action: String) -> String {
        "\(event.run?.rawValue ?? ""):\(action)"
    }

    private func describe(_ action: ProposedAction?, id: String) -> String {
        guard let action else { return "Action \(id)" }
        let target = action.target.map { " \($0)" } ?? ""
        return "\(action.kind.prefix(1).uppercased())\(action.kind.dropFirst())\(target)"
    }

    private mutating func apply(_ event: Event) throws {
        switch event.type.rawValue {
        case RunEventType.decision:
            let decision = try event.payload(as: RunDecision.self).decision
            add(event, "decision", "Decided \(decision.choice)", reason: decision.rationale)
        case ActionEventType.proposed:
            let body = try event.payload(as: ActionProposed.self)
            proposed[key(event, body.action.id)] = body.action
            if body.disposition == .deny {
                add(
                    event, "action", "\(describe(body.action, id: body.action.id)) (denied)",
                    reason: body.reason)
            }
        case ActionEventType.executed:
            let body = try event.payload(as: ActionExecuted.self)
            let action = proposed[key(event, body.action)]
            add(
                event, "action", "\(describe(action, id: body.action)) (executed)",
                reason: action?.rationale)
        case ActionEventType.failed:
            let body = try event.payload(as: ActionFailed.self)
            add(
                event, "action",
                "\(describe(proposed[key(event, body.action)], id: body.action)) (failed)",
                reason: body.error, unresolved: true)
        case ActionEventType.rejected:
            let body = try event.payload(as: ActionRejected.self)
            add(
                event, "action",
                "\(describe(proposed[key(event, body.action)], id: body.action)) (rejected)",
                reason: body.reason)
        case ApprovalEventType.requested:
            let body = try event.payload(as: ApprovalRequested.self)
            let what = body.question ?? describe(body.action, id: body.action?.id ?? "")
            add(
                event, "approval", "Asked \(body.to): \(what)", reason: body.action?.rationale,
                unresolved: true)
        case ApprovalEventType.granted, ApprovalEventType.denied:
            let verb = event.type.rawValue == ApprovalEventType.granted ? "Approved" : "Denied"
            add(
                event, "approval", "\(verb) by \(event.actor.id)",
                reason: event.payload["note"]?.stringValue)
        case RunEventType.finished:
            let body = try event.payload(as: RunFinished.self)
            add(event, "run", "Run finished (\(body.status.rawValue))", reason: body.summary)
        case RunEventType.failed:
            let body = try event.payload(as: RunFailed.self)
            add(
                event, "run", "Run failed (\(body.reason))", reason: body.detail,
                unresolved: true)
        case "memory.added":
            add(
                event, "memory", "Remembered a note",
                reason: event.payload["note"]?["text"]?.stringValue)
        case "routine.promoted":
            add(event, "routine", "Routine \(event.payload["name"]?.stringValue ?? "") went live")
        case StewardEventType.charterUpdated:
            add(event, "charter", "Charter changed", reason: event.payload["reason"]?.stringValue)
        default:
            return
        }
    }
}
