import AryaAdapters
import AryaCore
import AryaLedger
import Foundation

// Learning from results (decision 0054). An executed action that acted on a target through an
// MCP binding with the `outcome` read tool (PROTOCOL.md "Binding conventions") gets follow-up
// checks: `FollowUps.delay` after it ran, arya asks the binding how the target stands now and
// records `action.checked`, linked to the action by its run and id. `resolved` and `reopened`
// settle it; `open` and `unknown` are checked again after another delay, up to `maxChecks`.
// `Effectiveness` scores each action kind from those checks and from the steward's metric:
// the change between two consecutive `metric.recorded` readings (in the metric's good
// direction) is split equally among the actions executed between them. Runs see the scores in
// their instructions ("What has worked"), and the facade shows them in the recap.

/// Event type of a follow-up check.
public enum OutcomeEventType {
    /// `action.checked`.
    public static let checked = EventType("action.checked")
}

/// `action.checked`: how an executed action's target stood at a follow-up check (actor:
/// system; steward and run: the action's).
public struct ActionChecked: Sendable, Hashable, Codable {
    /// The action's id within its run.
    public var action: String
    public var kind: String
    public var binding: String
    public var target: String
    /// 1 for the first check of this action.
    public var attempt: Int
    /// `resolved`, `reopened`, `open`, `unknown`, or the binding's own word (lowercased).
    public var status: String
    /// When the binding says the status was reached.
    public var at: String?
    /// The binding's note, cut to 280 characters.
    public var note: String?
    /// A number the outcome moved, when the binding reports a finite one.
    public var metric: OutcomeMetric?

    /// True when this check settles the action.
    public var settles: Bool { ["resolved", "reopened"].contains(status) }

    public init(
        action: String, kind: String, binding: String, target: String, attempt: Int,
        status: String, at: String? = nil, note: String? = nil, metric: OutcomeMetric? = nil
    ) {
        self.action = action
        self.kind = kind
        self.binding = binding
        self.target = target
        self.attempt = attempt
        self.status = status
        self.at = at
        self.note = note
        self.metric = metric
    }

    /// The record for a binding's `outcome` answer, normalized: an empty status is `unknown`,
    /// the note is cut, and a non-finite metric is dropped.
    static func normalized(_ result: JSONValue, for followUp: FollowUp) -> ActionChecked {
        let body = result["structuredContent"] ?? result
        let raw =
            body["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        var metric: OutcomeMetric?
        if let name = body["metric"]?["name"]?.stringValue, !name.isEmpty,
            let value = body["metric"]?["value"]?.doubleValue, value.isFinite
        {
            let delta = body["metric"]?["delta"]?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
            metric = OutcomeMetric(
                name: name, value: value, delta: delta, unit: body["metric"]?["unit"]?.stringValue)
        }
        let note = body["note"]?.stringValue.map { String($0.prefix(280)) }
        return ActionChecked(
            action: followUp.action.id, kind: followUp.action.kind, binding: followUp.binding.id,
            target: followUp.target, attempt: followUp.attempt,
            status: raw.isEmpty ? "unknown" : String(raw.prefix(40)),
            at: body["at"]?.stringValue, note: note?.isEmpty == true ? nil : note, metric: metric)
    }
}

/// An executed action due for a follow-up check.
public struct FollowUp: Sendable, Hashable {
    public var steward: StewardID
    public var run: RunID
    public var action: ProposedAction
    public var target: String
    public var binding: CharterBinding
    /// When the action ran.
    public var executedAt: Timestamp
    /// 1 for the first check.
    public var attempt: Int
}

/// Which executed actions are due for a follow-up check.
public enum FollowUps {
    /// The read tool a binding answers follow-up checks with.
    public static let tool = "outcome"
    /// Default wait before each check: one hour.
    public static let delay: Int64 = 3_600_000
    /// Checks per action at most.
    public static let maxChecks = 3

    /// The follow-ups due at `now`, oldest action first.
    public static func due(
        _ events: [RuntimeEvent], now: Timestamp, delay: Int64 = delay,
        maxChecks: Int = maxChecks
    ) throws -> [FollowUp] {
        let stewards = try StewardBook(events)
        var proposed: [String: ProposedAction] = [:]
        var checks: [String: (count: Int, last: Timestamp, settled: Bool)] = [:]
        var executed: [(RuntimeEvent, String)] = []
        for event in events {
            guard let run = event.draft.run else { continue }
            switch event.type {
            case ActionEventType.proposed:
                if let body = try? Payload.decode(ActionProposed.self, event.payload) {
                    proposed[key(run, body.action.id)] = body.action
                }
            case ActionEventType.executed:
                // A draft (dry run) changed nothing, so there is nothing to follow up.
                if let id = event.payload["action"]?.stringValue, event.payload["dryRun"] != true {
                    executed.append((event, id))
                }
            case OutcomeEventType.checked.rawValue:
                guard let body = try? Payload.decode(ActionChecked.self, event.payload) else {
                    continue
                }
                let k = key(run, body.action)
                let count = (checks[k]?.count ?? 0) + 1
                checks[k] = (count, event.at, (checks[k]?.settled ?? false) || body.settles)
            default:
                continue
            }
        }
        var due: [FollowUp] = []
        for (event, id) in executed {
            guard let run = event.draft.run, let steward = event.draft.steward,
                let record = stewards.records[steward], record.status != .retired,
                let action = proposed[key(run, id)], let target = action.target,
                let binding = action.binding.flatMap(record.charter.binding),
                binding.kind == .mcp, binding.read.contains(tool)
            else { continue }
            let past = checks[key(run, id)]
            if past?.settled == true || (past?.count ?? 0) >= maxChecks { continue }
            let from = past?.last ?? event.at
            guard now.millis >= from.millis + delay else { continue }
            due.append(
                FollowUp(
                    steward: steward, run: run, action: action, target: target,
                    binding: binding, executedAt: event.at, attempt: (past?.count ?? 0) + 1))
        }
        return due
    }

    private static func key(_ run: RunID, _ action: String) -> String {
        run.rawValue + "/" + action
    }
}

/// Runs due follow-up checks through each binding's `outcome` tool.
public struct OutcomeChecker: Sendable {
    let sink: any EventSink
    let connect: @Sendable (CharterBinding) async throws -> any ToolUpstream
    let delay: Int64

    /// Creates a checker that connects to bindings with `connect` (for example
    /// `BindingActionExecutor.spawn`) and waits `delay` milliseconds before each check.
    public init(
        sink: any EventSink, delay: Int64 = FollowUps.delay,
        connect: @escaping @Sendable (CharterBinding) async throws -> any ToolUpstream
    ) {
        self.sink = sink
        self.delay = delay
        self.connect = connect
    }

    /// Checks every follow-up due at `now`; returns the recorded checks and any errors (a
    /// failed check is tried again at the next pass).
    public func check(now: Timestamp) async throws -> (
        checked: [ActionChecked], errors: [String]
    ) {
        let due = try FollowUps.due(try await sink.events(from: 1), now: now, delay: delay)
        var checked: [ActionChecked] = []
        var errors: [String] = []
        for followUp in due {
            let params = OutcomeCheckParams(
                target: followUp.target, action: followUp.action.kind,
                since: followUp.executedAt.description)
            do {
                let upstream = try await connect(followUp.binding)
                let result: JSONValue
                do {
                    result = try await upstream.call(
                        FollowUps.tool, arguments: try Payload.encode(params))
                    await upstream.close()
                } catch {
                    await upstream.close()
                    throw error
                }
                if result["isError"]?.boolValue == true {
                    errors.append("\(followUp.binding.id): outcome tool error")
                    continue
                }
                let record = ActionChecked.normalized(result, for: followUp)
                _ = try await sink.append(
                    RuntimeEventDraft(
                        type: OutcomeEventType.checked.rawValue, steward: followUp.steward,
                        run: followUp.run, actor: .system, payload: try Payload.encode(record)))
                checked.append(record)
            } catch {
                errors.append("\(followUp.binding.id): \(error)")
            }
        }
        return (checked, errors)
    }
}

/// How well one action kind has worked for a steward.
public struct KindEffect: Sendable, Hashable, Codable {
    public var kind: String
    public var executed: Int
    public var failed: Int
    public var resolved: Int
    public var reopened: Int
    /// Checks that have not settled yet (`open` or `unknown` at the latest check).
    public var pending: Int
    /// Metric change credited to this kind, in the metric's good direction (positive is good).
    public var credit: Double
    /// Executed actions that shared in some metric window.
    public var credited: Int
    /// Actions only drafted (dry runs): never checked or credited.
    public var drafted: Int = 0

    /// Resolved among settled checks, when any settled.
    public var successRate: Double? {
        resolved + reopened == 0 ? nil : Double(resolved) / Double(resolved + reopened)
    }

    /// Average credit per credited action, when any.
    public var creditPerAction: Double? { credited == 0 ? nil : credit / Double(credited) }

    /// One line for instructions and recaps, for example
    /// `label: 4 of 5 resolved, metric +0.020 per action (6 executed)`.
    public var line: String {
        var parts: [String] = []
        if resolved + reopened > 0 {
            parts.append("\(resolved) of \(resolved + reopened) resolved")
        }
        if let per = creditPerAction { parts.append("metric \(Self.signed(per)) per action") }
        if failed > 0 { parts.append("\(failed) failed") }
        if drafted > 0 { parts.append("\(drafted) drafted, not sent") }
        let detail = parts.isEmpty ? "no results yet" : parts.joined(separator: ", ")
        return "\(kind): \(detail) (\(executed) executed)"
    }

    static func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + String(format: "%.3f", value)
    }
}

/// Scores a steward's action kinds from follow-up checks and windowed metric credit.
public enum Effectiveness {
    /// Effects per action kind for `steward`, by kind name; kinds it never executed are absent.
    public static func of(_ steward: StewardID, in events: [RuntimeEvent]) throws -> [KindEffect] {
        guard let record = try StewardBook(events).records[steward] else { return [] }
        var fold = EffectFold()
        for event in events { fold.apply(event) }
        return fold.effects(steward, metric: record.charter.metric)
    }
}

/// The running tally behind `Effectiveness`, folded one event at a time so a run start reads
/// only the events appended since the last one (decision 0057). Metric credit is kept raw per
/// metric name and turned into "good" by the charter's direction when read, so a charter edit
/// never needs a refold.
public struct EffectFold: Sendable {
    private struct Tally: Sendable {
        var kinds: [String: String] = [:]  // run/action -> kind
        var counts: [String: (executed: Int, failed: Int, drafted: Int)] = [:]
        var latest: [String: ActionChecked] = [:]  // run/action -> latest check
        var executed: [String] = []  // kinds of real executions, in order
        var readings: [String: (value: Double, mark: Int)] = [:]  // metric -> last, window start
        var credit: [String: [String: (sum: Double, count: Int)]] = [:]  // metric -> kind
    }

    private var tallies: [StewardID: Tally] = [:]

    public init() {}

    /// Folds one event.
    public mutating func apply(_ event: RuntimeEvent) {
        guard let steward = event.draft.steward else { return }
        let run = event.draft.run?.rawValue ?? ""
        switch event.type {
        case ActionEventType.proposed:
            if let body = try? Payload.decode(ActionProposed.self, event.payload) {
                tallies[steward, default: Tally()].kinds[run + "/" + body.action.id] =
                    body.action.kind
            }
        case ActionEventType.executed, ActionEventType.failed:
            guard let id = event.payload["action"]?.stringValue,
                let kind = tallies[steward]?.kinds[run + "/" + id]
            else { return }
            var count = tallies[steward]?.counts[kind] ?? (0, 0, 0)
            if event.type == ActionEventType.failed {
                count.failed += 1
            } else if event.payload["dryRun"] == true {
                count.drafted += 1
            } else {
                count.executed += 1
                tallies[steward]?.executed.append(kind)
            }
            tallies[steward]?.counts[kind] = count
        case OutcomeEventType.checked.rawValue:
            if let body = try? Payload.decode(ActionChecked.self, event.payload) {
                tallies[steward, default: Tally()].latest[run + "/" + body.action] = body
            }
        case MetricEventType.recorded:
            guard let body = try? Payload.decode(MetricRecorded.self, event.payload),
                body.value.isFinite
            else { return }
            var tally = tallies[steward] ?? Tally()
            let end = tally.executed.count
            if let previous = tally.readings[body.metric], previous.mark < end {
                let window = tally.executed[previous.mark..<end]
                let share = (body.value - previous.value) / Double(window.count)
                for kind in window {
                    let old = tally.credit[body.metric]?[kind] ?? (0, 0)
                    tally.credit[body.metric, default: [:]][kind] = (old.sum + share, old.count + 1)
                }
            }
            tally.readings[body.metric] = (body.value, end)
            tallies[steward] = tally
        default:
            return
        }
    }

    /// Effects per action kind for `steward` under `metric`.
    public func effects(_ steward: StewardID, metric: Metric) -> [KindEffect] {
        guard let tally = tallies[steward] else { return [] }
        var effects: [String: KindEffect] = [:]
        func effect(_ kind: String) -> KindEffect {
            effects[kind]
                ?? KindEffect(
                    kind: kind, executed: 0, failed: 0, resolved: 0, reopened: 0, pending: 0,
                    credit: 0, credited: 0)
        }
        for (kind, count) in tally.counts {
            var e = effect(kind)
            e.executed = count.executed
            e.failed = count.failed
            e.drafted = count.drafted
            effects[kind] = e
        }
        let sign: Double = metric.direction == .down ? -1 : 1
        for (kind, credit) in tally.credit[metric.name] ?? [:] {
            var e = effect(kind)
            e.credit = sign * credit.sum
            e.credited = credit.count
            effects[kind] = e
        }
        for check in tally.latest.values {
            var e = effect(check.kind)
            switch check.status {
            case "resolved": e.resolved += 1
            case "reopened": e.reopened += 1
            default: e.pending += 1
            }
            effects[check.kind] = e
        }
        return effects.values.sorted { $0.kind < $1.kind }
    }
}
