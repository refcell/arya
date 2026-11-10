import AryaCore
import AryaRuntime
import Foundation

/// How one run's actions turned out, read from the follow-up checks (`action.checked`) that
/// came days or weeks after it: the run is graded on its executed actions' latest statuses.
public struct TrajectoryGrade: Hashable, Sendable, Codable {
    public var run: String
    /// The run's decision choices, in order.
    public var choices: [String]
    /// Executed (not dry-run) actions, and how many settled `resolved` or `reopened`.
    public var actions: Int
    public var resolved: Int
    public var reopened: Int
    /// `good` (every settled action resolved), `bad` (any reopened), or `pending`.
    public var grade: String
    /// Days from the action to the check that settled it, the longest in the run.
    public var lagDays: Double?
}

/// Credit for one action kind or one decision choice over every graded run.
public struct TrajectoryCredit: Hashable, Sendable, Codable, Identifiable {
    /// `kind` or `choice`.
    public var axis: String
    public var name: String
    public var resolved: Int
    public var reopened: Int
    public var pending: Int
    /// resolved / (resolved + reopened), nil until one settles.
    public var rate: Double?
    /// 0...1, the lower end of the 95% interval on `rate` (Wilson): few outcomes stay low
    /// even when every one resolved, so Impact can weigh evidence, not just a rate.
    public var confidence: Double
    /// Median days from the action to the check that settled it.
    public var medianLagDays: Double?
    /// One line, shown verbatim: `label: resolved 10 of 12, checked a median 9 days later`.
    public var line: String
    public var id: String { axis + ":" + name }
}

/// Trajectory grading for a steward: each run graded on later outcomes, and credit assigned
/// to the action kinds and decision choices those runs took.
public struct TrajectoryGradesView: Hashable, Sendable, Codable {
    public var steward: String
    /// Newest run first; runs with no executed action are left out.
    public var runs: [TrajectoryGrade]
    /// Kinds, then choices; each by confidence, highest first.
    public var credits: [TrajectoryCredit]
    public var good: Int
    public var bad: Int
    public var pending: Int
    /// One sentence, shown verbatim.
    public var sentence: String

    /// The credit for an action kind, if it ran.
    public func kind(_ name: String) -> TrajectoryCredit? {
        credits.first { $0.axis == "kind" && $0.name == name }
    }
}

/// Builds `TrajectoryGradesView`s from a steward's events. Deterministic and read-only.
public enum TrajectoryGrades {
    static let day = 86_400_000.0

    public static func view(steward: StewardID, events: [RuntimeEvent]) -> TrajectoryGradesView {
        struct Action {
            var kind: String
            var executedAt: Int64?
            var status: String?
            var checkedAt: Int64?
        }
        var order: [String] = []
        var choices: [String: [String]] = [:]
        var actions: [String: [String: Action]] = [:]
        for event in events where event.draft.steward == steward {
            guard let run = event.draft.run?.rawValue else { continue }
            if actions[run] == nil && choices[run] == nil { order.append(run) }
            switch event.type {
            case "run.decision":
                if let choice = event.payload["decision"]?["choice"]?.stringValue {
                    choices[run, default: []].append(choice)
                }
            case ActionEventType.proposed:
                if let id = event.payload["action"]?["id"]?.stringValue,
                    let kind = event.payload["action"]?["kind"]?.stringValue
                {
                    actions[run, default: [:]][id] = Action(kind: kind)
                }
            case ActionEventType.executed:
                guard let id = event.payload["action"]?.stringValue,
                    // A draft (top-level dryRun) changed nothing, as runtime's follow-ups say.
                    event.payload["dryRun"] != true,
                    actions[run]?[id] != nil
                else { continue }
                actions[run]?[id]?.executedAt = event.at.millis
            case OutcomeEventType.checked.rawValue:
                // The latest check of an action wins.
                guard let id = event.payload["action"]?.stringValue,
                    let status = event.payload["status"]?.stringValue,
                    actions[run]?[id]?.executedAt != nil
                else { continue }
                actions[run]?[id]?.status = status
                actions[run]?[id]?.checkedAt = event.at.millis
            default:
                continue
            }
        }

        var grades: [TrajectoryGrade] = []
        var tallies: [String: (resolved: Int, reopened: Int, pending: Int, lags: [Double])] = [:]
        for run in order {
            let done = (actions[run] ?? [:]).values.filter { $0.executedAt != nil }
            guard !done.isEmpty else { continue }
            var resolved = 0
            var reopened = 0
            var lags: [Double] = []
            var outcomes: [(kind: String, status: String?, lag: Double?)] = []
            for action in done.sorted(by: { $0.kind < $1.kind }) {
                let settled = ["resolved", "reopened"].contains(action.status ?? "")
                let lag =
                    settled
                    ? action.checkedAt.flatMap { checked in
                        action.executedAt.map { Double(checked - $0) / day }
                    } : nil
                if action.status == "resolved" { resolved += 1 }
                if action.status == "reopened" { reopened += 1 }
                if let lag { lags.append(lag) }
                outcomes.append((action.kind, settled ? action.status : nil, lag))
            }
            let grade = reopened > 0 ? "bad" : resolved > 0 ? "good" : "pending"
            grades.append(
                TrajectoryGrade(
                    run: run, choices: choices[run] ?? [], actions: done.count,
                    resolved: resolved, reopened: reopened, grade: grade, lagDays: lags.max()))
            // Kinds get their own actions' outcomes; each choice gets the run's outcomes.
            func tally(_ key: String, _ status: String?, _ lag: Double?) {
                var entry = tallies[key] ?? (0, 0, 0, [])
                switch status {
                case "resolved": entry.resolved += 1
                case "reopened": entry.reopened += 1
                default: entry.pending += 1
                }
                if let lag { entry.lags.append(lag) }
                tallies[key] = entry
            }
            for outcome in outcomes { tally("kind:" + outcome.kind, outcome.status, outcome.lag) }
            for choice in Set(choices[run] ?? []) {
                let status = grade == "good" ? "resolved" : grade == "bad" ? "reopened" : nil
                tally("choice:" + choice, status, lags.max())
            }
        }

        let credits = tallies.map { key, entry in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let settled = entry.resolved + entry.reopened
            let lag = median(entry.lags)
            var line = "\(parts[1]): "
            line +=
                settled == 0
                ? "\(entry.pending) not checked yet"
                : "resolved \(entry.resolved) of \(settled)"
            if let lag { line += ", checked a median \(days(lag)) later" }
            return TrajectoryCredit(
                axis: parts[0], name: parts[1], resolved: entry.resolved,
                reopened: entry.reopened, pending: entry.pending,
                rate: settled == 0 ? nil : Double(entry.resolved) / Double(settled),
                confidence: wilsonLower(entry.resolved, settled), medianLagDays: lag, line: line)
        }
        .sorted {
            ($0.axis == "kind" ? 0 : 1, -$0.confidence, $0.name)
                < ($1.axis == "kind" ? 0 : 1, -$1.confidence, $1.name)
        }
        let good = grades.filter { $0.grade == "good" }.count
        let bad = grades.filter { $0.grade == "bad" }.count
        let pending = grades.count - good - bad
        return TrajectoryGradesView(
            steward: steward.rawValue, runs: grades.reversed(), credits: credits, good: good,
            bad: bad, pending: pending,
            sentence: sentence(good: good, bad: bad, pending: pending, credits: credits))
    }

    static func sentence(good: Int, bad: Int, pending: Int, credits: [TrajectoryCredit])
        -> String
    {
        let graded = good + bad
        guard graded > 0 else {
            return pending == 0
                ? "No executed actions to grade yet."
                : "\(pending) run\(pending == 1 ? "" : "s") acted; no follow-up check has "
                    + "settled yet."
        }
        // One definition for the text and the panel's tally: a run is graded once a follow-up
        // check settled one of its actions; the rest acted and are still open.
        let runs = graded + pending
        var text = "\(graded) of \(runs) run\(runs == 1 ? "" : "s") have checked outcomes: "
        text += "\(good) good, \(bad) reopened"
        if pending > 0 { text += "; \(pending) still open" }
        if let best = credits.first(where: { $0.axis == "kind" && $0.rate != nil }) {
            text += "; best evidence: \(best.line)"
        }
        return text + "."
    }

    /// The lower end of the 95% Wilson interval for `k` successes in `n`; 0 when `n` is 0.
    static func wilsonLower(_ k: Int, _ n: Int) -> Double {
        guard n > 0 else { return 0 }
        let z = 1.96
        let p = Double(k) / Double(n)
        let n = Double(n)
        let center = p + z * z / (2 * n)
        let margin = z * ((p * (1 - p) + z * z / (4 * n)) / n).squareRoot()
        return max(0, (center - margin) / (1 + z * z / n))
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func days(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded < 1 ? "under a day" : "\(rounded) day\(rounded == 1 ? "" : "s")"
    }
}
