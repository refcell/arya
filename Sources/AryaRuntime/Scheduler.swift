import AryaAdapters
import AryaCore
import Foundation

// Triggers. Exactly one process holds `scheduler.lock` and fires interval and message
// triggers; other processes only start manual runs (ARCHITECTURE.md "Durability"). Only ready,
// unpaused stewards take live triggers.

/// Which stewards' interval triggers are due. Pure: the same books and time give the same plan.
public enum SchedulePlan {
    /// Stewards (by id) whose interval trigger is due at `now`.
    ///
    /// A steward is due when it takes live triggers, has an interval trigger (the shortest wins),
    /// has no open live run, and either never ran on a schedule, last started a scheduled run at
    /// least one interval ago, or its last scheduled run was interrupted (re-queued after a
    /// restart).
    public static func due(stewards: StewardBook, runs: RunBook, now: Timestamp) -> [StewardID] {
        stewards.all.compactMap { steward in
            status(of: steward, runs: runs, now: now, recent: 0).state == .due ? steward.id : nil
        }
    }

    /// Where `steward`'s schedule stands at `now`, with its last `recent` live top-level runs
    /// (newest first) and how they ended.
    public static func status(
        of steward: StewardRecord, runs: RunBook, now: Timestamp, recent: Int = 10
    ) -> ScheduleStatus {
        let live = runs.all.filter {
            $0.steward == steward.id && !$0.rehearsal && $0.parent == nil
        }
        let outcomes = live.suffix(max(0, recent)).reversed().map(TriggerOutcome.init)
        let every = interval(steward.charter)
        func status(_ state: ScheduleStatus.State, _ next: Timestamp?) -> ScheduleStatus {
            ScheduleStatus(
                steward: steward.id, state: state, intervalSeconds: every, nextWake: next,
                recent: Array(outcomes))
        }
        guard steward.takesLiveTriggers else { return status(.off, nil) }
        guard let every else { return status(.unscheduled, nil) }
        if live.contains(where: { $0.status == .running }) { return status(.running, nil) }
        guard let last = live.last(where: { $0.trigger == RunInputKind.schedule.rawValue }),
            last.failureReason != RunFailureReason.interrupted.rawValue
        else { return status(.due, now) }
        let next = last.startedAt.adding(milliseconds: Int64(every) * 1000)
        return status(now >= next ? .due : .waiting, next)
    }

    /// The shortest interval trigger of a charter, in seconds.
    public static func interval(_ charter: Charter) -> Int? {
        charter.triggers.compactMap { trigger -> Int? in
            if case .interval(let seconds) = trigger, seconds > 0 { return seconds }
            return nil
        }.min()
    }

    /// True when `charter` takes a message from `sender`, a person binding id: a `message`
    /// trigger with no `from`, or with `from` equal to the sender.
    public static func takesMessage(_ charter: Charter, from sender: String) -> Bool {
        charter.triggers.contains { trigger in
            if case .message(let from) = trigger { return from == nil || from == sender }
            return false
        }
    }
}

/// A steward's schedule at one moment (`SchedulePlan.status`).
public struct ScheduleStatus: Sendable, Hashable {
    public enum State: String, Sendable, Hashable {
        /// Not ready, paused, or retired: no live triggers fire.
        case off
        /// Takes live triggers but has no interval trigger.
        case unscheduled
        /// A live run is open; the next wake is set when it ends.
        case running
        /// The next tick starts a scheduled run.
        case due
        /// Waiting for `nextWake`.
        case waiting
    }

    public var steward: StewardID
    public var state: State
    /// The shortest interval trigger, in seconds.
    public var intervalSeconds: Int?
    /// When the next scheduled run starts: `now` when due; nil when off, unscheduled, or running.
    public var nextWake: Timestamp?
    /// The last live top-level runs, newest first.
    public var recent: [TriggerOutcome]
}

/// How one triggered run went.
public struct TriggerOutcome: Sendable, Hashable {
    public var run: RunID
    /// `schedule`, `message`, `manual`, or `join`.
    public var trigger: String
    public var status: RunRecord.Status
    /// The failure reason (`budget`, `timeout`, `interrupted`, ...) of a failed run.
    public var failureReason: String?
    public var summary: String?
    public var startedAt: Timestamp
    public var endedAt: Timestamp?

    init(_ record: RunRecord) {
        run = record.id
        trigger = record.trigger
        status = record.status
        failureReason = record.failureReason
        summary = record.summary
        startedAt = record.startedAt
        endedAt = record.endedAt
    }
}

/// Fires triggers: scheduled runs on `tick`, message runs on `deliver`. Runs go in the
/// background; `settle()` waits for them. Hold `SchedulerLock` before creating one.
public actor Scheduler {
    let engine: RunEngine
    private let finished: (@Sendable (RunOutcome) async -> Void)?
    private var scheduled: Set<StewardID> = []
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextTask = 0
    /// Demo pace, when on (decision 0051).
    var demoPacer: DemoPacer?

    /// Creates a scheduler that starts runs through `engine`.
    /// `finished` sees every run the scheduler started once it ends (the facade records the
    /// routines a run proposed); its errors are the caller's to handle.
    public init(engine: RunEngine, finished: (@Sendable (RunOutcome) async -> Void)? = nil) {
        self.engine = engine
        self.finished = finished
    }

    /// Starts a scheduled run for every due steward; returns the stewards it started.
    @discardableResult
    public func tick(now: Timestamp) async throws -> [StewardID] {
        // The cached books: a pass reads the events since the last one, not the history (0057).
        let due = SchedulePlan.due(
            stewards: try await engine.sink.book(StewardBook.self),
            runs: try await engine.sink.book(RunBook.self), now: now
        ).filter { !scheduled.contains($0) }
        for steward in due {
            scheduled.insert(steward)
            let input = RunInput(kind: .schedule, text: "Scheduled run.")
            launch(RunRequest(steward: steward, input: input, mode: .live, actor: .system)) {
                await $0.unschedule(steward)
            }
        }
        return due
    }

    /// Starts a message run if `steward` takes live triggers and a message from `sender` (a
    /// person binding id; the run's actor is that person).
    /// Returns false (and records nothing) when it does not.
    @discardableResult
    public func deliver(
        _ text: String, from sender: String, to steward: StewardID,
        attachments: [JSONValue] = []
    ) async throws -> Bool {
        let record = try await StewardLifecycle(sink: engine.sink).book().records[steward]
        guard let record, record.takesLiveTriggers,
            SchedulePlan.takesMessage(record.charter, from: sender)
        else { return false }
        let input = RunInput(kind: .message, text: text, attachments: attachments)
        launch(RunRequest(steward: steward, input: input, mode: .live, actor: .person(sender))) {
            _ in
        }
        return true
    }

    /// Every steward's schedule at `now`, with its last `recent` triggered runs.
    public func status(now: Timestamp, recent: Int = 10) async throws -> [ScheduleStatus] {
        let runs = try await engine.sink.book(RunBook.self)
        return try await engine.sink.book(StewardBook.self).all.map {
            SchedulePlan.status(of: $0, runs: runs, now: now, recent: recent)
        }
    }

    /// Starts a re-plan of `run` for `setbacks` in the background (see `RunEngine.replan`), for
    /// setbacks found after the run ended: denied, expired, or failed approved actions.
    public func replan(after run: RunID, steward: StewardID, setbacks: [Setback]) {
        guard !setbacks.isEmpty else { return }
        let key = nextTask
        nextTask += 1
        let engine = engine
        let finished = finished
        tasks[key] = Task {
            if let outcome = try? await engine.replan(
                after: run, steward: steward, setbacks: setbacks)
            {
                await finished?(outcome)
            }
            await self.forget(key)
        }
    }

    /// Ticks every `interval` (by `engine`'s ambient clock) until the task is cancelled.
    public func run(every interval: Duration) async throws {
        while !Task.isCancelled {
            try await tick(now: engine.ambient.now())
            try await Task.sleep(for: interval)
        }
    }

    /// Waits for every run started so far.
    public func settle() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    func launch(
        _ request: RunRequest, then done: @escaping @Sendable (Scheduler) async -> Void
    ) {
        let key = nextTask
        nextTask += 1
        let engine = engine
        let finished = finished
        tasks[key] = Task {
            // A run records its own failures; only ledger errors throw, and the next tick
            // (or a restart's recovery) sees whatever reached the ledger.
            if let outcome = try? await engine.run(request) { await finished?(outcome) }
            await done(self)
            await self.forget(key)
        }
    }

    private func unschedule(_ steward: StewardID) { scheduled.remove(steward) }

    private func forget(_ key: Int) { tasks[key] = nil }
}

/// `<home>/scheduler.lock`, held with `flock` by the one process that fires triggers. The
/// kernel releases it when that process dies.
public final class SchedulerLock: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?

    private init(fd: Int32) { self.fd = fd }

    /// Takes the lock in `home`, or returns nil when another process holds it.
    public static func acquire(home: URL) throws -> SchedulerLock? {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let path = home.appendingPathComponent("scheduler.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw RunLeaseError.unavailable("open scheduler.lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return SchedulerLock(fd: fd)
    }

    /// True when some process holds the lock in `home`. Probes with a non-blocking shared
    /// lock that is dropped at once, so a serving process is never disturbed.
    public static func isHeld(home: URL) -> Bool {
        let path = home.appendingPathComponent("scheduler.lock").path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    /// Releases the lock; later calls do nothing.
    public func release() {
        lock.withLock {
            guard let fd else { return }
            flock(fd, LOCK_UN)
            close(fd)
            self.fd = nil
        }
    }

    deinit { release() }
}
