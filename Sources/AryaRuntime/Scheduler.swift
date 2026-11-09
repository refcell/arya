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
            guard steward.takesLiveTriggers, let every = interval(steward.charter) else {
                return nil
            }
            let live = runs.all.filter {
                $0.steward == steward.id && !$0.rehearsal && $0.parent == nil
            }
            if live.contains(where: { $0.status == .running }) { return nil }
            guard let last = live.last(where: { $0.trigger == RunInputKind.schedule.rawValue })
            else { return steward.id }
            if last.failureReason == RunFailureReason.interrupted.rawValue { return steward.id }
            let next = last.startedAt.adding(milliseconds: Int64(every) * 1000)
            return now >= next ? steward.id : nil
        }
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

/// Fires triggers: scheduled runs on `tick`, message runs on `deliver`. Runs go in the
/// background; `settle()` waits for them. Hold `SchedulerLock` before creating one.
public actor Scheduler {
    private let engine: RunEngine
    private let finished: (@Sendable (RunOutcome) async -> Void)?
    private var scheduled: Set<StewardID> = []
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextTask = 0

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
        let events = try await engine.sink.events(from: 1)
        let due = SchedulePlan.due(
            stewards: try StewardBook(events), runs: try RunBook(events), now: now
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
    public func deliver(_ text: String, from sender: String, to steward: StewardID) async throws
        -> Bool
    {
        let record = try await StewardLifecycle(sink: engine.sink).book().records[steward]
        guard let record, record.takesLiveTriggers,
            SchedulePlan.takesMessage(record.charter, from: sender)
        else { return false }
        let input = RunInput(kind: .message, text: text)
        launch(RunRequest(steward: steward, input: input, mode: .live, actor: .person(sender))) {
            _ in
        }
        return true
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

    private func launch(
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
