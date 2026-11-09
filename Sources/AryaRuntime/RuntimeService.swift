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
}

/// The long-running side of arya (`arya serve`, M4): the one process holding `scheduler.lock`.
/// On start it recovers interrupted runs; each tick it expires due approvals, fires due
/// triggers, and announces new pending approvals.
public actor RuntimeService {
    private let engine: RunEngine
    private let scheduler: Scheduler
    private let recovery: RunRecovery
    private let notifier: (any ApprovalNotifier)?
    private var announced: Set<ApprovalID> = []

    /// Creates a service. `recovery` must share `engine`'s leases.
    public init(engine: RunEngine, recovery: RunRecovery, notifier: (any ApprovalNotifier)? = nil) {
        self.engine = engine
        self.scheduler = Scheduler(engine: engine)
        self.recovery = recovery
        self.notifier = notifier
    }

    /// Fails runs whose process is gone; scheduled ones are re-queued by the next tick.
    @discardableResult
    public func recover() async throws -> [RunRecord] {
        try await recovery.recover()
    }

    /// One pass at `now`.
    @discardableResult
    public func tick(now: Timestamp) async throws -> ServiceTick {
        let expired = try await engine.approvals.expireDue(now: now).map(\.id)
        let scheduled = try await scheduler.tick(now: now)
        let fresh = try await engine.approvals.book().pending.filter {
            !announced.contains($0.id)
        }
        announced.formUnion(fresh.map(\.id))
        if let notifier, !fresh.isEmpty { await notifier.pending(fresh) }
        return ServiceTick(expired: expired, scheduled: scheduled, announced: fresh.map(\.id))
    }

    /// Delivers a message trigger (see `Scheduler.deliver`).
    @discardableResult
    public func deliver(_ text: String, from sender: String, to steward: StewardID)
        async throws -> Bool
    {
        try await scheduler.deliver(text, from: sender, to: steward)
    }

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
