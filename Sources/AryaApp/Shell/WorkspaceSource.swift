import Arya
import AryaDesign
import Foundation

/// What the app reads and writes through the facade. `Workspace` conforms; the tests use an
/// in-memory `FakeWorkspaceSource`.
protocol WorkspaceSource: Sendable {
    /// A short label for the window subtitle: the home's folder name or "Preview".
    var label: String { get }
    func stewards() async throws -> [StewardSummary]
    func runs(steward: String?) async throws -> [RunSummary]
    func approvals(includeDecided: Bool) async throws -> [ApprovalSummary]
    func pauseSteward(_ id: String) async throws
    func resumeSteward(_ id: String) async throws
    /// Starts a manual run and returns once it finishes or fails.
    func startRun(steward: String, input: String) async throws -> RunSummary
    func approve(_ id: String, note: String?) async throws -> ApprovalSummary
    func deny(_ id: String, note: String?) async throws -> ApprovalSummary
    func ledger(from seq: Int, limit: Int?) async throws -> [LedgerEntry]
    func events(from seq: Int) -> AsyncThrowingStream<LedgerEntry, Error>
    func verifyLedger() async throws -> LedgerCheck
    /// Each steward's charter effort (`low`, `medium`, `high`) by steward id.
    func efforts() async throws -> [String: String]
    /// Changes a steward's charter effort.
    func setEffort(_ effort: String, steward: String) async throws
    /// Records one feature-view write, attributed to the local person.
    func record(_ write: FeatureWrite) async throws
    /// A routine version's body, or nil if it is missing.
    func routineBody(steward: String, name: String, version: String) async throws -> String?
    /// One case's expected result in a casebook version, or nil if it is missing.
    func expectedResult(casebook: String, caseID: String) async throws -> FeatureJSON?
    /// Replays a run from the ledger alone.
    func replayRun(_ run: String) async throws -> FeatureReplayResult
    /// One event's inspector detail.
    func eventDetail(seq: Int) async throws -> FeatureEventDetail?
    /// The Improve screen's sentences.
    func improveSummary(steward: String) async throws -> FeatureImproveSummary
    /// The Knowledge screen's notes and routines.
    func knowledgeSummary(steward: String) async throws -> FeatureKnowledge
    /// A run replayed under a proposal's charter, in one line.
    func whatIfSummary(run: String, proposal: String) async throws -> String
    /// A proposal backtested against the live charter.
    func liveReadinessSummary(proposal: String) async throws -> FeatureLiveReadiness
    /// Each pending approval's policy sentence and change line.
    func approvalTexts() async throws -> [String: FeatureApprovalText]
    /// Starts a connection's server with its secret and lists its tools (the Test button).
    func probeConnection(command: String, args: [String], declared: [String], secret: String?)
        async throws -> ConnectionProbe
}

extension WorkspaceSource {
    func probeConnection(command: String, args: [String], declared: [String], secret: String?)
        async throws -> ConnectionProbe
    {
        throw FeatureReadError.unavailable("connection tests")
    }

    func routineBody(steward: String, name: String, version: String) async throws -> String? {
        throw FeatureReadError.unavailable("routine bodies")
    }

    func expectedResult(casebook: String, caseID: String) async throws -> FeatureJSON? {
        throw FeatureReadError.unavailable("expected results")
    }

    func replayRun(_ run: String) async throws -> FeatureReplayResult {
        throw FeatureReadError.unavailable("replay")
    }

    func eventDetail(seq: Int) async throws -> FeatureEventDetail? {
        throw FeatureReadError.unavailable("event detail")
    }

    func improveSummary(steward: String) async throws -> FeatureImproveSummary {
        throw FeatureReadError.unavailable("improve summary")
    }

    func knowledgeSummary(steward: String) async throws -> FeatureKnowledge {
        throw FeatureReadError.unavailable("knowledge")
    }

    func whatIfSummary(run: String, proposal: String) async throws -> String {
        throw FeatureReadError.unavailable("What if")
    }

    func liveReadinessSummary(proposal: String) async throws -> FeatureLiveReadiness {
        throw FeatureReadError.unavailable("backtest")
    }

    func approvalTexts() async throws -> [String: FeatureApprovalText] {
        throw FeatureReadError.unavailable("approval summaries")
    }
}

extension Workspace: WorkspaceSource {
    nonisolated var label: String { home.lastPathComponent }

    func probeConnection(command: String, args: [String], declared: [String], secret: String?)
        async throws -> ConnectionProbe
    {
        // The app's own environment (for PATH), plus the secret; nothing is recorded.
        try await ConnectionProbe.run(
            command: command, args: args, declared: declared,
            environment: ConnectionCredential.environment(
                ProcessInfo.processInfo.environment, secret: secret))
    }

    func efforts() async throws -> [String: String] {
        var efforts: [String: String] = [:]
        for steward in try await stewards() {
            efforts[steward.id] = try await effort(for: steward.id)
        }
        return efforts
    }

    func setEffort(_ effort: String, steward: String) async throws {
        try await setEffort(effort, for: steward, by: Self.person)
    }

    /// The person the app acts for until person bindings land (M4).
    nonisolated static let person = "local"

    func record(_ write: FeatureWrite) async throws {
        let person = Self.person
        switch write {
        case .approve(let approval):
            _ = try await approve(approval, note: nil)
        case .deny(let approval, let reason):
            _ = try await deny(approval, note: reason.isEmpty ? nil : reason)
        case .acceptProposal(let id):
            _ = try await acceptProposal(id, by: person)
        case .rejectProposal(let id, let reason):
            _ = try await rejectProposal(id, reason: reason.isEmpty ? nil : reason, by: person)
        case .overrideProposal(let id, let reason):
            _ = try await overrideProposal(id, reason: reason, by: person)
        case .retractMemory(let note, let reason):
            _ = try await retract(memory: note, reason: reason.isEmpty ? nil : reason, by: person)
        case .correctCase(let correction):
            _ = try await correct(
                steward: correction.steward, case: correction.caseID,
                expected: try correction.expected.map(Self.canonical),
                note: correction.text.isEmpty ? nil : correction.text,
                casebook: correction.casebook, by: person)
        case .correctRun(_, let run, let choice, let note):
            _ = try await correct(
                run: run, expected: try await expected(run: run, choice: choice),
                note: note.isEmpty ? nil : note, by: person)
        case .markReady(let steward, _, _):
            // The facade checks the reviewed rehearsal and live charter version itself.
            _ = try await markReady(steward: steward, by: person)
        case .proposeCharter(let proposal):
            let proposed = try await proposeCharter(
                steward: proposal.steward, charter: try Self.canonical(proposal.charter),
                baseVersion: proposal.baseVersion, title: proposal.title, reason: proposal.reason,
                by: person)
            // Gate it on the casebook right away, as the CLI does; live readiness is on demand.
            // A steward without a casebook keeps the proposal open.
            do {
                _ = try await checkProposal(proposed.id)
            } catch WorkspaceError.notFound {}
        case .startRun(let steward, let input):
            _ = try await startRun(steward: steward, input: input)
        case .message:
            // Waits on a facade call that posts `inbox.message` as the local person.
            throw FeatureReadError.unavailable("messaging a steward")
        case .rehearse(let steward, let casebook):
            _ = try await rehearse(steward: steward, casebook: casebook)
        case .answer(let approval, let text):
            // A person binding's answer to a question approves it with the answer as the note.
            _ = try await approve(approval, note: text)
        case .createSteward(let draft):
            _ = try await createSteward(draft)
        }
    }

    func routineBody(steward: String, name: String, version: String) async throws -> String? {
        try await routineContent(steward: steward, name: name, version: version)
    }

    func expectedResult(casebook: String, caseID: String) async throws -> FeatureJSON? {
        guard let data = try await caseExpected(casebook: casebook, case: caseID) else {
            return nil
        }
        return try JSONDecoder().decode(FeatureJSON.self, from: data)
    }

    func replayRun(_ run: String) async throws -> FeatureReplayResult {
        Self.featureReplay(try await replay(run: run))
    }

    func eventDetail(seq: Int) async throws -> FeatureEventDetail? {
        guard let detail = try await event(seq: seq) else { return nil }
        return FeatureEventDetail(
            payloadText: detail.payloadText, hash: detail.hash, prev: detail.prev,
            step: detail.step.map {
                FeatureEventDetail.Step(
                    run: $0.run, index: $0.index, count: $0.count, title: $0.title)
            })
    }

    func knowledgeSummary(steward: String) async throws -> FeatureKnowledge {
        let view = try await knowledge(steward: steward)
        let now = Date()
        return FeatureKnowledge(
            notes: view.notes.map {
                FeatureKnowledge.Note(
                    id: $0.note.id, text: $0.note.text, provenance: $0.provenance,
                    time: AryaTime.label($0.time.date, now: now),
                    absoluteTime: AryaTime.absolute($0.time.date, timeZone: .current),
                    run: $0.note.run)
            },
            routines: view.routines.map { item in
                FeatureKnowledge.Routine(
                    name: item.routine.name, summary: item.routine.summary,
                    versions: item.versions.map {
                        FeatureKnowledge.Version(
                            version: $0.version, summary: $0.summary, approval: $0.approval,
                            time: AryaTime.label($0.time.date, now: now))
                    },
                    isLive: item.routine.liveVersion != nil, pending: item.routine.pending)
            })
    }

    func improveSummary(steward: String) async throws -> FeatureImproveSummary {
        let view = try await improve(steward: steward)
        return FeatureImproveSummary(
            rehearsal: view.rehearsal?.id, rehearsalText: view.rehearsalText, ready: view.ready,
            markedReady: view.markedReady, readinessText: view.readinessText,
            readinessReasons: view.readinessReasons,
            cases: view.cases.map {
                FeatureImproveSummary.Case(
                    id: $0.caseID, wouldHave: $0.wouldHave, expected: $0.expected, diff: $0.diff,
                    passed: $0.passed, leak: $0.leak)
            },
            gates: Dictionary(
                view.proposals.map { ($0.proposal.id, $0.gate) }, uniquingKeysWith: { a, _ in a }))
    }

    func whatIfSummary(run: String, proposal: String) async throws -> String {
        try await whatIf(run: run, proposal: proposal).summary
    }

    func liveReadinessSummary(proposal: String) async throws -> FeatureLiveReadiness {
        let found = try await liveReadiness(proposal: proposal)
        return FeatureLiveReadiness(
            ready: found.ready, summary: found.summary, regressions: found.regressions,
            improved: found.improved, runsChecked: found.runsChecked)
    }

    func approvalTexts() async throws -> [String: FeatureApprovalText] {
        Self.approvalTexts(try await approvals())
    }

    /// The facade's approval sentences by id, shown verbatim.
    nonisolated static func approvalTexts(_ summaries: [ApprovalSummary])
        -> [String: FeatureApprovalText]
    {
        Dictionary(
            summaries.map {
                ($0.id, FeatureApprovalText(policy: $0.policyText, change: $0.change?.text))
            }, uniquingKeysWith: { first, _ in first })
    }

    /// A facade replay summary in the feature views' shape.
    nonisolated static func featureReplay(_ summary: ReplaySummary) -> FeatureReplayResult {
        FeatureReplayResult(
            run: summary.run, events: summary.events,
            divergences: summary.divergences.map {
                FeatureReplayResult.Divergence(
                    index: $0.index, seq: $0.seq, type: $0.type, field: $0.field,
                    recorded: $0.recorded, replayed: $0.replayed)
            })
    }

    nonisolated static func canonical(_ json: FeatureJSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(json)
    }
}
