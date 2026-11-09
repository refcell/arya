import Foundation

/// An in-memory workspace for previews, screenshots, and tests. It turns writes into the
/// events the runtime would record, with a pinned clock and sequential ids, so it is fully
/// deterministic. Deleted once the facade offers an equivalent in-memory workspace.
actor PreviewWorkspace: FeatureWorkspace {
    private var log: [FeatureEvent]
    private var clock: Date
    private var nextID = 1
    private var broken: (seq: Int, reason: String)?
    private var routines: [String: String]
    private var expected: [String: FeatureJSON]
    private var texts: [String: FeatureApprovalText]
    private var divergent: Set<String> = []
    private var subscribers: [Int: AsyncStream<Void>.Continuation] = [:]
    private var nextSubscriber = 0

    /// - Parameters:
    ///   - routines: routine bodies keyed by version.
    ///   - expected: expected case results keyed by `casebook/case`.
    ///   - approvalTexts: the workspace's sentences by approval id; copy them from the facade,
    ///     never write new ones here.
    init(
        events: [FeatureEvent], now: Date, routines: [String: String] = [:],
        expected: [String: FeatureJSON] = [:], approvalTexts: [String: FeatureApprovalText] = [:]
    ) {
        log = events
        clock = now
        self.routines = routines
        self.expected = expected
        texts = approvalTexts
    }

    func approvalTexts() -> [String: FeatureApprovalText] { texts }

    /// The fixture workspace used by previews and the stub app.
    static func triage(now: Date) -> PreviewWorkspace {
        PreviewWorkspace(
            events: PreviewFixtures.triage(now: now), now: now,
            routines: PreviewFixtures.routineBodies, expected: PreviewFixtures.expectedResults)
    }

    func caseExpected(casebook: String, caseID: String) -> FeatureJSON? {
        expected["\(casebook)/\(caseID)"]
    }

    func routineContent(steward: String, name: String, version: String) -> String? {
        routines[version]
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
        case .retractMemory(let note, let reason):
            let added = try liveNote(note)
            emit(
                added, "memory.retracted", .localUser,
                ["v": 1, "note": .string(note), "reason": .string(reason)])
        case .correctCase(let correction): try correct(correction)
        case .correctRun(let steward, let run, let choice, let note):
            try correct(
                CaseCorrection(
                    steward: steward, casebook: "corrections", caseID: "case-\(run)", text: note,
                    expected: ["decisions": [["choice": .string(choice)]]], rehearsal: nil,
                    run: run))
        case .proposeCharter(let proposal): try propose(proposal)
        case .startRun(let steward, let input):
            let run = "run_w\(nextID)"
            emit(
                steward: steward, run: run, "run.started", .localUser,
                ["trigger": "manual", "input": .string(input)])
        case .rehearse(let steward, let casebook): rehearse(steward: steward, casebook: casebook)
        case .createSteward(let draft):
            emit(
                steward: draft.id, run: nil, "steward.created", .localUser,
                ["charter": NewStewardPreview.charter(draft), "version": 1])
        case .answer(let approval, let text):
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty { throw FeatureWriteError.answerEmpty }
            let request = try pendingRequest(approval)
            emit(
                request, "approval.granted", .localUser,
                ["approval": .string(approval), "note": .string(answer)])
        case .markReady(let steward, let version, let rehearsal):
            var payload: FeatureJSON = ["v": 1, "charterVersion": .number(Double(version))]
            if let rehearsal, case .object(var members) = payload {
                members["rehearsal"] = .string(rehearsal)
                payload = .object(members)
            }
            emit(steward: steward, run: nil, "steward.ready", .localUser, payload)
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

    private func liveNote(_ id: String) throws -> FeatureEvent {
        guard
            let added = log.first(where: {
                $0.type == "memory.added" && $0.payload["note"]?["id"]?.string == id
            })
        else { throw FeatureWriteError.unknownNote(id) }
        if log.contains(where: { $0.type == "memory.retracted" && $0.payload["note"]?.string == id }
        ) {
            throw FeatureWriteError.alreadyRetracted(id)
        }
        return added
    }

    /// Replays match the recording exactly in preview, except runs listed in `divergent`.
    func eventDetail(seq: Int) async throws -> FeatureEventDetail? {
        let all = try await events()
        guard let index = all.firstIndex(where: { $0.seq == seq }) else { return nil }
        let event = all[index]
        let step = event.run.map { run -> FeatureEventDetail.Step in
            let own = all.filter { $0.run == run }
            let position = (own.firstIndex { $0.seq == seq } ?? 0) + 1
            let title = LedgerTable.runTitles(all)[run] ?? ""
            return FeatureEventDetail.Step(
                run: run, index: position, count: own.count, title: title)
        }
        return FeatureEventDetail(
            payloadText: event.payload.prettyText, hash: event.hash,
            prev: index > 0 ? all[index - 1].hash : "", step: step)
    }

    func replay(run: String) async throws -> FeatureReplayResult {
        let events = log.filter { $0.run == run }
        guard !events.isEmpty else { throw FeatureReadError.unavailable("run \(run)") }
        guard divergent.contains(run), let last = events.last else {
            return FeatureReplayResult(run: run, events: events.count, divergences: [])
        }
        let divergence = FeatureReplayResult.Divergence(
            index: events.count - 1, seq: last.seq, type: last.type, field: "payload.output",
            recorded: #"{"payload":{"output":"recorded"},"type":"\#(last.type)"}"#,
            replayed: #"{"payload":{"output":"changed"},"type":"\#(last.type)"}"#)
        return FeatureReplayResult(run: run, events: events.count, divergences: [divergence])
    }

    /// Runs whose replay reports a divergence, for previews and tests.
    func markDivergent(_ run: String) { divergent.insert(run) }

    /// `rehearsal.started` for the live charter, copying the cases of the last rehearsal.
    private func rehearse(steward: String, casebook: String?) {
        let live = LiveCharter.find(events: log, steward: steward)?.version ?? 0
        let last = log.last { $0.steward == steward && $0.type == "rehearsal.started" }
        let book = casebook ?? last?.payload["casebookVersion"]?.string ?? ""
        emit(
            steward: steward, run: nil, "rehearsal.started", .localUser,
            [
                "v": 1, "rehearsal": .string("rh_w\(nextID)"),
                "charterVersion": .number(Double(live)), "casebookVersion": .string(book),
                "cases": last?.payload["cases"] ?? 0, "samples": 1,
            ])
    }

    /// `proposal.created` for a candidate charter one version above the live one.
    private func propose(_ proposal: CharterProposal) throws {
        let live = LiveCharter.find(events: log, steward: proposal.steward)?.version ?? 0
        if live != proposal.baseVersion { throw FeatureWriteError.staleCharter(live: live) }
        let payload: FeatureJSON = [
            "id": .string("pr_w\(nextID)"), "kind": "charter",
            "candidateVersion": .number(Double(live + 1)), "title": .string(proposal.title),
            "reason": .string(proposal.reason), "charter": proposal.charter,
        ]
        emit(steward: proposal.steward, run: nil, "proposal.created", .localUser, payload)
    }

    /// `case.corrected` plus the memory note a correction becomes, both by the person.
    private func correct(_ c: CaseCorrection) throws {
        let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && c.expected == nil { throw FeatureWriteError.correctionEmpty }
        var payload: [String: FeatureJSON] = [
            "v": 1, "casebook": .string(c.casebook), "case": .string(c.caseID),
            "text": .string(text),
        ]
        payload["expected"] = c.expected
        payload["rehearsal"] = c.rehearsal.map(FeatureJSON.string)
        payload["run"] = c.run.map(FeatureJSON.string)
        emit(steward: c.steward, run: nil, "case.corrected", .localUser, .object(payload))
        guard !text.isEmpty else { return }
        let note: FeatureJSON = [
            "id": .string("note_w\(nextID)"), "text": .string(text), "tags": ["correction"],
            "provenance": [
                "case": .string(c.caseID), "event": .string("ev_w\(nextID - 1)"),
                "author": ["kind": "human", "id": "local"],
            ],
        ]
        emit(steward: c.steward, run: nil, "memory.added", .localUser, ["v": 1, "note": note])
    }

    private func emit(
        _ cause: FeatureEvent, _ type: String, _ actor: FeatureActor, _ payload: FeatureJSON
    ) {
        emit(steward: cause.steward, run: cause.run, type, actor, payload)
    }

    private func emit(
        steward: String?, run: String?, _ type: String, _ actor: FeatureActor,
        _ payload: FeatureJSON
    ) {
        clock = clock.addingTimeInterval(1)
        log.append(
            FeatureEvent(
                seq: (log.last?.seq ?? 0) + 1, id: "ev_w\(nextID)", at: clock, steward: steward,
                run: run, actor: actor, type: type, payload: payload))
        nextID += 1
    }
}
