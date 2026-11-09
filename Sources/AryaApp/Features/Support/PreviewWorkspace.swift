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
                [
                    "action": request.payload["action"]?["id"] ?? .null,
                    "approval": .string(approval), "output": "recorded",
                ])
        case .deny(let approval, let reason):
            let request = try pendingRequest(approval)
            emit(
                request, "approval.denied", .localUser,
                ["approval": .string(approval), "note": .string(reason)])
        case .acceptProposal(let id):
            let created = try openProposal(id, gate: true)
            emit(created, "proposal.accepted", .localUser, ["proposal": .string(id)])
        case .rejectProposal(let id, let reason):
            let created = try openProposal(id, gate: nil)
            emit(
                created, "proposal.rejected", .localUser,
                ["proposal": .string(id), "reason": .string(reason)])
        case .overrideProposal(let id, let reason):
            let created = try openProposal(id, gate: false)
            let payload: FeatureJSON = ["proposal": .string(id), "reason": .string(reason)]
            emit(created, "proposal.overridden", .localUser, payload)
            emit(created, "proposal.accepted", .localUser, payload)
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
                $0.type == "approval.requested" && $0.payload["approval"]?.string == approval
            })
        else { throw FeatureWriteError.unknownApproval(approval) }
        let decided = log.contains {
            ["approval.granted", "approval.denied", "approval.expired"].contains($0.type)
                && $0.payload["approval"]?.string == approval
        }
        if decided { throw FeatureWriteError.alreadyDecided(approval) }
        return request
    }

    /// The proposal's creation event, if it is still open and its latest gate result is
    /// `gate` (nil accepts any result, including none).
    private func openProposal(_ id: String, gate: Bool?) throws -> FeatureEvent {
        guard
            let created = log.first(where: {
                $0.type == "proposal.created" && $0.payload["id"]?.string == id
            })
        else { throw FeatureWriteError.unknownProposal(id) }
        let related = log.filter { $0.payload["proposal"]?.string == id }
        if related.contains(where: { ["proposal.accepted", "proposal.rejected"].contains($0.type) })
        {
            throw FeatureWriteError.proposalClosed(id)
        }
        guard let gate else { return created }
        let passed = related.last(where: { $0.type == "proposal.gated" })?.payload["passed"]?.bool
        if gate && passed != true { throw FeatureWriteError.gateNotPassed(id) }
        if !gate && passed != false {
            throw passed == true
                ? FeatureWriteError.gatePassed(id) : FeatureWriteError.gateNotPassed(id)
        }
        return created
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
