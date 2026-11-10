import AryaCore
import Foundation

/// Hears about approvals that are newly waiting for a person (for example to post a macOS
/// notification).
public protocol ApprovalNotifier: Sendable {
    /// Called once per approval, the first tick it is seen pending.
    func pending(_ approvals: [ApprovalRecord]) async
}

/// What one service tick did.
public struct ServiceTick: Sendable, Hashable {
    /// Approvals that expired.
    public var expired: [ApprovalID]
    /// Stewards whose scheduled run started.
    public var scheduled: [StewardID]
    /// Approvals newly announced to the notifier.
    public var announced: [ApprovalID]
    /// Messages posted from relay bindings.
    public var relayed: Int = 0
    /// Relays that failed this tick, as `<steward>/<binding>: <error>`; the next tick retries.
    public var relayErrors: [String] = []
    /// Follow-up checks recorded this tick (decision 0054).
    public var checked: Int = 0
    /// Follow-up checks that failed (tried again next tick).
    public var checkErrors: [String] = []
}

/// The long-running side of arya (`arya serve`, M4): the one process holding `scheduler.lock`.
/// On start it recovers interrupted runs; each tick it expires due approvals, fires due
/// triggers, and announces new pending approvals.
public actor RuntimeService {
    private let engine: RunEngine
    private let scheduler: Scheduler
    private let recovery: RunRecovery
    private let notifier: (any ApprovalNotifier)?
    private let relays: (@Sendable (CharterBinding) async throws -> any ToolUpstream)?
    private var announced: Set<ApprovalID> = []
    private let outcomes: OutcomeChecker?

    /// Creates a service. `recovery` must share `engine`'s leases. With `relays`, each tick
    /// pulls messages from every relay binding (decision 0042) of stewards that take live
    /// triggers, connecting with it (for example `BindingActionExecutor.spawn`).
    public init(
        engine: RunEngine, recovery: RunRecovery, notifier: (any ApprovalNotifier)? = nil,
        relays: (@Sendable (CharterBinding) async throws -> any ToolUpstream)? = nil,
        outcomes: OutcomeChecker? = nil
    ) {
        self.outcomes = outcomes
        self.engine = engine
        self.scheduler = Scheduler(engine: engine)
        self.recovery = recovery
        self.notifier = notifier
        self.relays = relays
    }

    /// Fails runs whose process is gone; scheduled ones are re-queued by the next tick.
    @discardableResult
    public func recover() async throws -> [RunRecord] {
        try await recovery.recover()
    }

    /// One pass at `now`.
    @discardableResult
    public func tick(now: Timestamp) async throws -> ServiceTick {
        let expiredRecords = try await engine.approvals.expireDue(now: now)
        for record in expiredRecords {
            if let setback = Setback(record) {
                await scheduler.replan(
                    after: record.run, steward: record.steward, setbacks: [setback])
            }
        }
        let expired = expiredRecords.map(\.id)
        let scheduled = try await scheduler.tick(now: now)
        let (relayed, relayErrors) = try await pullRelays()
        let checks = try await outcomes?.check(now: now)
        let fresh = try await engine.approvals.book().pending.filter {
            !announced.contains($0.id)
        }
        announced.formUnion(fresh.map(\.id))
        if let notifier, !fresh.isEmpty { await notifier.pending(fresh) }
        var result = ServiceTick(
            expired: expired, scheduled: scheduled, announced: fresh.map(\.id), relayed: relayed,
            relayErrors: relayErrors)
        result.checked = checks?.checked.count ?? 0
        result.checkErrors = checks?.errors ?? []
        return result
    }

    private func pullRelays() async throws -> (Int, [String]) {
        guard let relays else { return (0, []) }
        var relayed = 0
        var errors: [String] = []
        for steward in try await StewardLifecycle(sink: engine.sink).book().all
        where steward.takesLiveTriggers {
            let ids = Set(steward.charter.bindings.compactMap { $0.kind == .person ? $0.via : nil })
            for id in ids.sorted() {
                do {
                    relayed += try await inbox.pull(id, steward: steward.id, connect: relays)
                        .receipts.count
                } catch {
                    errors.append("\(steward.id.rawValue)/\(id): \(error)")
                }
            }
        }
        return (relayed, errors)
    }

    /// Delivers a message trigger (see `Scheduler.deliver`).
    @discardableResult
    public func deliver(_ text: String, from sender: String, to steward: StewardID)
        async throws -> Bool
    {
        try await scheduler.deliver(text, from: sender, to: steward)
    }

    /// Every steward's next wake and last `recent` trigger outcomes (see `Scheduler.status`).
    public func schedule(recent: Int = 10) async throws -> [ScheduleStatus] {
        try await scheduler.status(now: engine.ambient.now(), recent: recent)
    }

    /// The local inbox, starting message runs through this service's scheduler.
    public var inbox: Inbox { Inbox(engine: engine, scheduler: scheduler) }

    /// Recovers, then ticks every `interval` by the engine's clock until cancelled; waits for
    /// started runs before returning.
    public func run(every interval: Duration) async throws {
        try await recover()
        while !Task.isCancelled {
            try await tick(now: engine.ambient.now())
            do { try await Task.sleep(for: interval) } catch { break }
        }
        await scheduler.settle()
    }

    /// Waits for every run started so far.
    public func settle() async { await scheduler.settle() }
}
