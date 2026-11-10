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
    /// Yields each time a live run's ledger grows; finishes when the run ends.
    func observeRun(_ run: String) -> AsyncStream<Void>
    /// One case's expected result in a casebook version, or nil if it is missing.
    func expectedResult(casebook: String, caseID: String) async throws -> FeatureJSON?
    /// Replays a run from the ledger alone.
    func replayRun(_ run: String) async throws -> FeatureReplayResult
    /// One event's inspector detail.
    func eventDetail(seq: Int) async throws -> FeatureEventDetail?
    /// The Improve screen's sentences.
    func improveSummary(steward: String) async throws -> FeatureImproveSummary
    /// The review queue on the steward's newest casebook, or nil when it has none.
    func reviewQueueSummary(steward: String) async throws -> FeatureReviewQueue?
    /// The learned checks, scored, or nil before anyone reviewed a case.
    func learnedChecksSummary(steward: String) async throws -> FeatureLearnedChecks?
    /// What worked (`Workspace.trajectories`).
    func trajectorySummary(steward: String) async throws -> FeatureTrajectories
    /// The go-live gate (`Workspace.goLiveGate`).
    func goLiveGateSummary(steward: String) async throws -> FeatureGoLiveGate
    /// The Knowledge screen's notes and routines.
    func knowledgeSummary(steward: String) async throws -> FeatureKnowledge
    /// What a steward is doing now (`Workspace.stewardLive`).
    func stewardLiveState(steward: String) async throws -> FeatureStewardLive
    /// The Overview's findings (`Workspace.overviewFindings`).
    func overviewFindingLines(steward: String) async throws -> [FeatureOverviewFinding]
    /// Which actions moved the metric (`Workspace.impact`).
    func impactSummary(steward: String) async throws -> FeatureImpact?
    /// Imports a binding's past items as cases (`Workspace.importHistory`); its summary line.
    func historyImport(steward: String, binding: String) async throws -> String
    /// `onboardingState`, the latest onboard run, and context notes.
    func onboardingSummary(steward: String) async throws -> FeatureOnboarding
    /// `Workspace.onboard(steward:)`, as one line.
    func onboardRun(steward: String) async throws -> String
    /// `Workspace.metricStatuses(steward:windows:)`.
    func metricStatusList(steward: String, windows: Int) async throws -> [FeatureMetricStatus]
    /// One person's thread with a steward, oldest first.
    func conversationEntries(steward: String, person: String) async throws
        -> [FeatureConversationEntry]
    /// A run replayed under a proposal's charter, in one line.
    func whatIfSummary(run: String, proposal: String) async throws -> String
    /// A proposal backtested against the live charter.
    func liveReadinessSummary(proposal: String) async throws -> FeatureLiveReadiness
    /// Each pending approval's policy sentence and change line.
    func approvalTexts() async throws -> [String: FeatureApprovalText]
    /// One run's numbers (`Workspace.runFacts`); nil when unknown.
    func featureRunFacts(run: String) async throws -> FeatureRunFacts?
    /// Whether a process (this app or `arya serve`) fires this home's triggers; nil when the
    /// source cannot tell.
    func schedulerServing() async -> Bool?
    /// Runs in progress with their step counts, oldest first; empty when none or unknown.
    func liveLines() async -> [LiveLine]
    /// Why the home is served (workspace `serveState().reason`): scheduler, runs, or off.
    func serveReason() async -> String?
    /// Each steward's live state (workspace `stewardLive(steward:)`), by id.
    func stewardLives(_ ids: [String]) async -> [String: StewardLive]
    /// Each steward's outcome status by id (workspace `fleet()`).
    func fleetStatus() async -> [String: String]
    /// Example stewards to start from (workspace `templates()`).
    func templates() -> [StewardTemplate]
    /// Each steward's department, by id, from workspace `portfolio()`; empty when unknown.
    func departments() async -> [String: String]
    /// Who serves the home and each steward's next wake (`Workspace.serveStatus`).
    func serveSchedule() async -> FeatureServe?
    /// Starts firing the home's triggers from this process; false when another one serves.
    func startServing() async throws -> Bool
    /// Starts a connection's server with its secret and lists its tools (the Test button).
    func probeConnection(command: String, args: [String], declared: [String], secret: String?)
        async throws -> ConnectionTest
    /// The periodic report a steward would send now (People's Report section).
    func reportDigest(steward: String) async throws -> ReportDigest
}

extension WorkspaceSource {
    func observeRun(_ run: String) -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func featureRunFacts(run: String) async throws -> FeatureRunFacts? { nil }

    func schedulerServing() async -> Bool? { nil }
    func serveSchedule() async -> FeatureServe? { nil }

    func startServing() async throws -> Bool {
        throw FeatureReadError.unavailable("serving")
    }

    func liveLines() async -> [LiveLine] { [] }

    func serveReason() async -> String? { nil }

    func stewardLives(_ ids: [String]) async -> [String: StewardLive] { [:] }

    func fleetStatus() async -> [String: String] { [:] }

    func templates() -> [StewardTemplate] { [] }

    func departments() async -> [String: String] { [:] }

    func reportDigest(steward: String) async throws -> ReportDigest {
        throw FeatureReadError.unavailable("reports")
    }

    func probeConnection(command: String, args: [String], declared: [String], secret: String?)
        async throws -> ConnectionTest
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

    func stewardLiveState(steward: String) async throws -> FeatureStewardLive {
        throw FeatureReadError.unavailable("steward live")
    }

    func overviewFindingLines(steward: String) async throws -> [FeatureOverviewFinding] {
        throw FeatureReadError.unavailable("findings")
    }

    func impactSummary(steward: String) async throws -> FeatureImpact? {
        throw FeatureReadError.unavailable("impact")
    }

    func historyImport(steward: String, binding: String) async throws -> String {
        throw FeatureReadError.unavailable("history import")
    }

    func onboardingSummary(steward: String) async throws -> FeatureOnboarding {
        throw FeatureReadError.unavailable("onboarding")
    }

    func onboardRun(steward: String) async throws -> String {
        throw FeatureReadError.unavailable("onboarding")
    }

    func metricStatusList(steward: String, windows: Int) async throws -> [FeatureMetricStatus] {
        throw FeatureReadError.unavailable("metric statuses")
    }

    func conversationEntries(steward: String, person: String) async throws
        -> [FeatureConversationEntry]
    {
        throw FeatureReadError.unavailable("conversation")
    }

    func reviewQueueSummary(steward: String) async throws -> FeatureReviewQueue? {
        throw FeatureReadError.unavailable("review queue")
    }

    func learnedChecksSummary(steward: String) async throws -> FeatureLearnedChecks? {
        throw FeatureReadError.unavailable("learned checks")
    }

    func trajectorySummary(steward: String) async throws -> FeatureTrajectories {
        throw FeatureReadError.unavailable("trajectories")
    }

    func goLiveGateSummary(steward: String) async throws -> FeatureGoLiveGate {
        throw FeatureReadError.unavailable("go-live gate")
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
    func featureRunFacts(run: String) async throws -> FeatureRunFacts? {
        guard let facts = try await runFacts(run: run) else { return nil }
        return FeatureRunFacts(
            running: facts.status == "running", started: facts.started.date,
            elapsedSeconds: facts.elapsedSeconds, decisions: facts.decisions,
            toolCalls: facts.toolCalls, actionsProposed: facts.actionsProposed,
            actionsApplied: facts.actionsApplied, actionsDrafted: facts.actionsDrafted,
            actionsWaiting: facts.actionsWaiting, stepIndex: facts.stepIndex,
            estimatedSteps: facts.estimatedSteps, dryRun: facts.dryRun)
    }

    nonisolated func observeRun(_ run: String) -> AsyncStream<Void> {
        let updates = observe(run: run)
        return AsyncStream { continuation in
            let task = Task {
                for await _ in updates { continuation.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated var label: String { home.lastPathComponent }

    func departments() async -> [String: String] {
        guard let portfolio = try? await portfolio() else { return [:] }
        var out: [String: String] = [:]
        for group in portfolio.groups {
            for item in group.items where item.department != nil {
                out[item.fleet.steward] = group.department
            }
        }
        return out
    }

    func liveLines() async -> [LiveLine] {
        ((try? await liveRuns()) ?? []).map {
            LiveLine(
                run: $0.run.id, steward: $0.run.steward, name: $0.stewardName, steps: $0.stepCount,
                lastStep: $0.lastStep, progress: $0.progress, started: $0.run.startedAt,
                elapsedSeconds: $0.elapsedSeconds, readAt: Date(),
                estimatedSteps: $0.estimatedSteps)
        }
    }

    func serveReason() async -> String? { (try? await serveState())?.reason }

    func fleetStatus() async -> [String: String] {
        Dictionary(
            ((try? await fleet()) ?? []).map { ($0.steward, $0.status) },
            uniquingKeysWith: { first, _ in first })
    }

    func stewardLives(_ ids: [String]) async -> [String: StewardLive] {
        var out: [String: StewardLive] = [:]
        for id in ids {
            if let live = try? await stewardLive(steward: id) { out[id] = live }
        }
        return out
    }

    func serveSchedule() async -> FeatureServe? {
        guard let status = try? await serveStatus() else { return nil }
        var serve = FeatureServe(serving: status.serving)
        for steward in status.stewards {
            serve.states[steward.steward] = steward.state
            if let wake = steward.nextWake { serve.wakes[steward.steward] = wake.date }
        }
        return serve
    }

    func startServing() async throws -> Bool {
        try startServing(every: .seconds(30))
    }

    /// Serving here, or another process holds `<home>/scheduler.lock` (the lock `arya serve`
    /// takes with an exclusive flock). The probe asks for a shared, non-blocking lock and
    /// drops it at once; nil when the home has no lock file to ask.
    func schedulerServing() async -> Bool? {
        if await isServing { return true }
        let path = home.appendingPathComponent("scheduler.lock").path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    func probeConnection(command: String, args: [String], declared: [String], secret: String?)
        async throws -> ConnectionTest
    {
        // The app's own environment (for PATH), plus the secret; nothing is recorded.
        await ConnectionTest.run(
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
        case .reviewCase(let steward, let caseID, let verdict):
            _ = try await reviewCase(steward: steward, case: caseID, verdict: verdict, by: person)
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
        case .message(let steward, let text, let intent, let by):
            // Records `inbox.message` as `by`; an ask or hand-off also runs the steward on it.
            _ = try await message(steward: steward, text: text, intent: intent.rawValue, by: by)
        case .rehearse(let steward, let casebook):
            _ = try await rehearse(steward: steward, casebook: casebook)
        case .answer(let approval, let text):
            // A person binding's answer to a question approves it with the answer as the note.
            _ = try await approve(approval, note: text)
        case .sendReport(let steward):
            _ = try await sendReport(steward: steward)
        case .createSteward(let draft):
            _ = try await createSteward(draft)
        case .adoptRoutine(let name, let version, let source, let target):
            _ = try await shareRoutine(
                name: name, version: version, from: source, into: target, by: person)
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

    func conversationEntries(steward: String, person: String) async throws
        -> [FeatureConversationEntry]
    {
        try await conversation(steward: steward, person: person).map {
            FeatureConversationEntry(
                seq: $0.seq, inbound: $0.direction == "inbound", intent: $0.intent, text: $0.text,
                run: $0.run)
        }
    }

    func stewardLiveState(steward: String) async throws -> FeatureStewardLive {
        let live = try await stewardLive(steward: steward)
        // The run's numbers through app-views' one wrapper, from the same cached tally.
        var facts: FeatureRunFacts?
        if let run = live.running?.run { facts = try await featureRunFacts(run: run) }
        return FeatureStewardLive(
            running: facts, run: live.running?.run,
            title: live.running?.title, progress: live.running?.progress,
            alsoRunning: live.alsoRunning, schedule: live.schedule,
            nextWake: live.nextWake?.date, serving: live.serving)
    }

    func overviewFindingLines(steward: String) async throws -> [FeatureOverviewFinding] {
        try await overviewFindings(steward: steward).map {
            FeatureOverviewFinding(kind: $0.kind, text: $0.text, link: $0.link?.kind)
        }
    }

    func historyImport(steward: String, binding: String) async throws -> String {
        try await importHistory(steward: steward, binding: binding).summary
    }

    func onboardingSummary(steward: String) async throws -> FeatureOnboarding {
        let state = try await onboardingState(steward: steward)
        let context = try await context(steward: steward)
        let notes =
            context.people.flatMap { person in
                person.notes.map { FeatureOnboarding.Note(about: person.id, text: $0) }
            }
            + context.connections.flatMap { connection in
                connection.notes.map { FeatureOnboarding.Note(about: connection.id, text: $0) }
            }
        return FeatureOnboarding(
            steps: state.steps.map {
                FeatureOnboarding.Step(
                    key: $0.key, title: $0.title, done: $0.done, detail: $0.detail)
            },
            summary: state.summary, notes: notes,
            onboardedAt: try await onboarding(steward: steward)?.at)
    }

    func metricStatusList(steward: String, windows: Int) async throws -> [FeatureMetricStatus] {
        try await metricStatuses(steward: steward, windows: windows).map {
            FeatureMetricStatus(
                name: $0.name, unit: $0.unit, direction: $0.direction, target: $0.target,
                role: $0.role, current: $0.current, trend: $0.trend.map(\.value),
                status: $0.status.rawValue, movement: $0.movement, line: $0.line)
        }
    }

    func onboardRun(steward: String) async throws -> String {
        guard let done = try await onboard(steward: steward) else {
            return "No connection lists people or processes to read."
        }
        return "Read \(done.sources.joined(separator: ", ")): \(done.notes) new notes, "
            + "\(done.people) people, \(done.queues) queues, \(done.rules) routing rules."
    }

    func impactSummary(steward: String) async throws -> FeatureImpact? {
        guard let impact = try await impact(steward: steward) else { return nil }
        return FeatureImpact(
            readings: impact.readings,
            rows: impact.rows.map {
                FeatureImpact.Row(
                    label: $0.label, credit: $0.credit, helped: $0.helped, actions: $0.actions,
                    windows: $0.windows, confidence: $0.confidenceLevel)
            }, summary: impact.summary)
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

    func reviewQueueSummary(steward: String) async throws -> FeatureReviewQueue? {
        guard let queue = try await reviewQueue(steward: steward) else { return nil }
        let item = { (item: ReviewQueueItem) in
            FeatureReviewQueue.Item(
                id: item.caseID, input: item.input, wouldHave: item.wouldHave,
                personDid: item.personDid, matches: item.matches, difference: item.difference,
                source: item.source, status: item.status.rawValue)
        }
        return FeatureReviewQueue(
            casebookVersion: queue.casebookVersion, rehearsal: queue.rehearsal,
            progressText: queue.progressText, total: queue.total, reviewed: queue.reviewed,
            next: queue.next.map(item))
    }

    func learnedChecksSummary(steward: String) async throws -> FeatureLearnedChecks? {
        guard let checks = try await learnedChecks(steward: steward) else { return nil }
        return FeatureLearnedChecks(
            version: checks.version, sentence: checks.sentence, total: checks.total,
            scored: checks.scored, passed: checks.passed,
            lines: checks.results.map { line in
                FeatureLearnedChecks.Line(
                    id: line.check.id, caseID: line.check.caseID.rawValue, text: line.check.text,
                    passed: line.passed, found: line.found, origin: line.check.origin.rawValue,
                    result: line.result)
            })
    }

    func whatIfSummary(run: String, proposal: String) async throws -> String {
        try await whatIf(run: run, proposal: proposal).summary
    }

    func trajectorySummary(steward: String) async throws -> FeatureTrajectories {
        let view = try await trajectories(steward: steward)
        return FeatureTrajectories(
            good: view.good, bad: view.bad, pending: view.pending, sentence: view.sentence,
            credits: view.credits.map {
                FeatureTrajectories.Credit(
                    id: $0.id, axis: $0.axis, name: $0.name, resolved: $0.resolved,
                    reopened: $0.reopened, pending: $0.pending, rate: $0.rate,
                    confidence: $0.confidence, medianLagDays: $0.medianLagDays, line: $0.line)
            })
    }

    func goLiveGateSummary(steward: String) async throws -> FeatureGoLiveGate {
        let gate = try await goLiveGate(steward: steward)
        return FeatureGoLiveGate(
            ready: gate.ready, summary: gate.summary,
            conditions: gate.conditions.map {
                FeatureGoLiveGate.Condition(key: $0.key, met: $0.met, detail: $0.detail)
            })
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
