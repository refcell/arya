import AryaCore
import AryaLedger
import AryaRuntime
import Foundation

// One source per fact (CEO decision): every screen reads run counts, durations, and progress
// from `runFacts(run:)` and `liveRuns()`, and a steward's live state from
// `stewardLive(steward:)`. All three read the same cached tally, so the header, inspector,
// sidebar, and status bar cannot disagree.

/// The numbers of one run.
public struct RunFacts: Sendable, Hashable, Codable {
    public var run: String
    public var steward: String
    /// `running`, `finished`, or `failed`.
    public var status: String
    public var title: String
    public var started: TimeText
    public var ended: TimeText?
    /// Seconds from start to end, or to now while running (the workspace clock).
    public var elapsedSeconds: Double
    public var decisions: Int
    public var toolCalls: Int
    public var actionsProposed: Int
    /// Executed for real.
    public var actionsApplied: Int
    /// Executed as drafts (dry run): nothing was sent.
    public var actionsDrafted: Int
    public var actionsFailed: Int
    /// Proposed actions held for a person and still waiting.
    public var actionsWaiting: Int
    /// Steps so far: rows the user sees in the run thread (`visibleSteps(run:)`), as
    /// `liveRuns()` shows.
    public var stepIndex: Int
    /// While running: the steward's usual steps per run (median of its last five ended runs),
    /// at least `stepIndex + 1`; nil once the run ended (`stepIndex` is then the steps done).
    public var estimatedSteps: Int?
    /// 0...1, the same estimate `liveRuns()` shows; 1 once ended.
    public var progress: Double?
    /// True when the run drafted actions and applied none.
    public var dryRun: Bool
}

/// What a steward is doing now, for NOW, the inspector's RUNNING, and SCHEDULE.
public struct StewardLive: Sendable, Hashable, Codable {
    public var steward: String
    /// The newest run in progress, with the same numbers as `liveRuns()`.
    public var running: RunFacts?
    /// Other runs in progress (crew children or overlapping wakes).
    public var alsoRunning: Int
    /// `off`, `unscheduled`, `running`, `due`, or `waiting`, as `serveStatus()` says.
    public var schedule: String
    public var intervalSeconds: Int?
    public var nextWake: TimeText?
    /// True when some process serves the home.
    public var serving: Bool
}

extension Workspace {
    /// One run's numbers, or nil when no run has this id.
    public func runFacts(run id: String, timeZone: TimeZone = .current) async throws
        -> RunFacts?
    {
        let state = try facadeState()
        let run = RunID(unchecked: id)
        guard let record = state.runs.records[run] else { return nil }
        return facts(record, state: state, now: now(), timeZone: timeZone)
    }

    /// What `steward` is doing now.
    public func stewardLive(steward: String, timeZone: TimeZone = .current) async throws
        -> StewardLive
    {
        let id = try await existing(steward).id
        let state = try facadeState()
        let now = now()
        let running = state.runs.all.filter { $0.steward == id && $0.status == .running }
        let status = try await serveStatus()
        let schedule = status.stewards.first { $0.steward == steward }
        return StewardLive(
            steward: steward,
            running: running.last.map { facts($0, state: state, now: now, timeZone: timeZone) },
            alsoRunning: max(0, running.count - 1), schedule: schedule?.state ?? "off",
            intervalSeconds: schedule?.intervalSeconds, nextWake: schedule?.nextWake,
            serving: status.serving)
    }

    func facts(_ record: RunRecord, state: FacadeState, now: Date, timeZone: TimeZone)
        -> RunFacts
    {
        let summary = RunSummary(record)
        var proposed = 0
        var applied = 0
        var drafted = 0
        var failed = 0
        var decisions = 0
        for event in state.byRun[record.id] ?? [] {
            switch event.type.rawValue {
            case ActionEventType.proposed: proposed += 1
            case ActionEventType.executed:
                if event.payload["dryRun"] == true { drafted += 1 } else { applied += 1 }
            case ActionEventType.failed: failed += 1
            case RunEventType.decision: decisions += 1
            default: continue
            }
        }
        // Tool calls as the TOOLS tab lists them (step records > proxy > adapter), from the
        // cached tally the step count uses.
        let tools = state.live.toolCalls(run: record.id)
        let waiting = state.approvals.pending.filter { $0.run == record.id }.count
        let end = summary.endedAt
        let elapsed = max(0, (end ?? now).timeIntervalSince(summary.startedAt))
        func time(_ date: Date) -> TimeText { TimeText(date, now: now, timeZone: timeZone) }
        return RunFacts(
            run: summary.id, steward: summary.steward, status: summary.status.rawValue,
            title: summary.title, started: time(summary.startedAt), ended: end.map(time),
            elapsedSeconds: elapsed, decisions: decisions, toolCalls: tools.count,
            actionsProposed: proposed, actionsApplied: applied, actionsDrafted: drafted,
            actionsFailed: failed, actionsWaiting: waiting,
            stepIndex: state.live.visibleSteps(run: record.id),
            estimatedSteps: state.live.estimate(run: record.id, steward: record.steward),
            progress: state.live.progress(run: record.id, steward: record.steward),
            dryRun: drafted > 0 && applied == 0)
    }
}
