import Foundation

/// An in-memory workspace for previews, screenshots, and tests. It turns writes into the
/// events the runtime would record, with a pinned clock and sequential ids, so it is fully
/// deterministic. Deleted once the facade offers an equivalent in-memory workspace.
actor PreviewWorkspace: FeatureWorkspace {
    private var log: [FeatureEvent]
    private var clock: Date
    private var nextID = 1
    private var broken: (seq: Int, reason: String)?
    private var subscribers: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextSubscriber = 0

    init(events: [FeatureEvent], now: Date) {
        log = events
        clock = now
    }

    /// The fixture workspace used by previews and the stub app.
    static func triage(now: Date) -> PreviewWorkspace {
        PreviewWorkspace(events: PreviewFixtures.triage(now: now), now: now)
    }

    func events() -> [FeatureEvent] { log }

    func verify() -> FeatureVerifyResult {
        if let broken { return .broken(seq: broken.seq, reason: broken.reason) }
        return .intact(events: log.count)
    }

    /// Makes `verify` report a break, for tests of the failure path.
    func simulateBreak(seq: Int, reason: String) { broken = (seq, reason) }

    /// Appends events as if another process wrote them, and notifies observers.
    func append(_ events: [FeatureEvent]) {
        log.append(contentsOf: events)
        notify()
    }

    @discardableResult
    func record(_ write: FeatureWrite) throws -> [FeatureEvent] {
        let start = log.count
        switch write {
        case .approve(let approval):
            let request = try pendingRequest(approval)
            emit(request, "approval.granted", .localUser, ["approval": .string(approval)])
            emit(
                request, "action.executed", FeatureActor(kind: .system, id: "arya"),
                ["action": request.payload["action"] ?? .null, "output": "recorded"])
        case .deny(let approval, let reason):
            let request = try pendingRequest(approval)
            emit(
                request, "approval.denied", .localUser,
                ["approval": .string(approval), "reason": .string(reason)])
        }
        notify()
        return Array(log[start...])
    }

    nonisolated func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        Task { await self.subscribe(continuation) }
        return stream
    }

    private func subscribe(_ continuation: AsyncStream<Void>.Continuation) {
        let key = nextSubscriber
        nextSubscriber += 1
        subscribers[key] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
    }

    private func unsubscribe(_ key: Int) { subscribers[key] = nil }

    private func notify() {
        for continuation in subscribers.values { continuation.yield() }
    }

    private func pendingRequest(_ approval: String) throws -> FeatureEvent {
        guard
            let request = log.first(where: {
                $0.type == "approval.requested" && $0.payload["id"]?.string == approval
            })
        else { throw FeatureWriteError.unknownApproval(approval) }
        let decided = log.contains {
            ["approval.granted", "approval.denied", "approval.expired"].contains($0.type)
                && $0.payload["approval"]?.string == approval
        }
        if decided { throw FeatureWriteError.alreadyDecided(approval) }
        return request
    }

    private func emit(
        _ cause: FeatureEvent, _ type: String, _ actor: FeatureActor, _ payload: FeatureJSON
    ) {
        clock = clock.addingTimeInterval(1)
        log.append(
            FeatureEvent(
                seq: (log.last?.seq ?? 0) + 1, id: "ev_w\(nextID)", at: clock,
                steward: cause.steward, run: cause.run, actor: actor, type: type,
                payload: payload))
        nextID += 1
    }
}
