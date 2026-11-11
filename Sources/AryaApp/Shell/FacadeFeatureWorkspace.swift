import Arya
import Foundation

/// Feeds the feature views (`FeatureWorkspace`) from the facade (`WorkspaceSource`). Payloads
/// are decoded from the canonical JSON text the facade returns; writes and reads go through the
/// source, which reports "not available yet" for anything the facade has no call for.
struct FacadeFeatureWorkspace: FeatureWorkspace {
    let source: any WorkspaceSource

    func events() async throws -> [FeatureEvent] {
        try await source.ledger(from: 1, limit: nil).map(Self.event)
    }

    @discardableResult
    func record(_ write: FeatureWrite) async throws -> [FeatureEvent] {
        try await source.record(write)
        // The store reloads every event after a write, so the appended events are not needed.
        return []
    }

    func routineContent(steward: String, name: String, version: String) async throws -> String? {
        try await source.routineBody(steward: steward, name: name, version: version)
    }

    func runFacts(run: String) async throws -> FeatureRunFacts? {
        try await source.featureRunFacts(run: run)
    }

    func observeRun(_ run: String) -> AsyncStream<Void> {
        source.observeRun(run)
    }

    func templates() -> [StewardTemplate] { source.templates() }

    func caseExpected(casebook: String, caseID: String) async throws -> FeatureJSON? {
        try await source.expectedResult(casebook: casebook, caseID: caseID)
    }

    func replay(run: String) async throws -> FeatureReplayResult {
        try await source.replayRun(run)
    }

    func approvalTexts() async throws -> [String: FeatureApprovalText] {
        try await source.approvalTexts()
    }

    func whatIf(run: String, proposal: String) async throws -> String {
        try await source.whatIfSummary(run: run, proposal: proposal)
    }

    func improveSummary(steward: String) async throws -> FeatureImproveSummary {
        try await source.improveSummary(steward: steward)
    }

    func liveReadiness(proposal: String) async throws -> FeatureLiveReadiness {
        try await source.liveReadinessSummary(proposal: proposal)
    }

    func reviewQueue(steward: String) async throws -> FeatureReviewQueue? {
        try await source.reviewQueueSummary(steward: steward)
    }

    func conversation(steward: String, person: String) async throws -> [FeatureConversationEntry] {
        try await source.conversationEntries(steward: steward, person: person)
    }

    func adapterLabels() async throws -> [String: String] { try await source.adapterLabelMap() }

    func personMemory(person: String) async throws -> [FeaturePersonNote] {
        try await source.personMemoryNotes(person: person)
    }

    func routineUpgrades() async throws -> [FeatureRoutineUpgrade] {
        try await source.routineUpgradeList()
    }

    func learnedChecks(steward: String) async throws -> FeatureLearnedChecks? {
        try await source.learnedChecksSummary(steward: steward)
    }

    func trajectories(steward: String) async throws -> FeatureTrajectories {
        try await source.trajectorySummary(steward: steward)
    }

    func goLiveGate(steward: String) async throws -> FeatureGoLiveGate {
        try await source.goLiveGateSummary(steward: steward)
    }

    func knowledge(steward: String) async throws -> FeatureKnowledge {
        try await source.knowledgeSummary(steward: steward)
    }

    func stewardLive(steward: String) async throws -> FeatureStewardLive {
        try await source.stewardLiveState(steward: steward)
    }

    func overviewFindings(steward: String) async throws -> [FeatureOverviewFinding] {
        try await source.overviewFindingLines(steward: steward)
    }

    func impact(steward: String) async throws -> FeatureImpact? {
        try await source.impactSummary(steward: steward)
    }

    func importHistory(steward: String, binding: String) async throws -> String {
        try await source.historyImport(steward: steward, binding: binding)
    }

    func onboarding(steward: String) async throws -> FeatureOnboarding {
        try await source.onboardingSummary(steward: steward)
    }

    func runOnboarding(steward: String) async throws -> String {
        try await source.onboardRun(steward: steward)
    }

    func metricStatuses(steward: String, windows: Int) async throws -> [FeatureMetricStatus] {
        try await source.metricStatusList(steward: steward, windows: windows)
    }

    func outcomeMissedText(steward: String) async throws -> String? {
        try await source.outcomeMissedText(steward: steward)
    }

    func runHistory(steward: String) async throws -> FeatureRunHistory {
        try await source.runHistorySummary(steward: steward)
    }

    func eventDetail(seq: Int) async throws -> FeatureEventDetail? {
        try await source.eventDetail(seq: seq)
    }

    func verify() async throws -> FeatureVerifyResult {
        let check = try await source.verifyLedger()
        if check.ok { return .intact(events: check.events) }
        return .broken(seq: check.firstBadSeq ?? 0, reason: check.detail ?? "unknown")
    }

    func changes() -> AsyncStream<Void> {
        let events = source.events(from: 1)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await _ in events { continuation.yield() }
                } catch {
                    // The shell reports a stopped stream through `AppModel.live`.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A facade ledger entry as a feature event. An undecodable payload becomes `null`.
    static func event(_ entry: LedgerEntry) -> FeatureEvent {
        let payload = (try? JSONDecoder().decode(FeatureJSON.self, from: Data(entry.payload.utf8)))
        return FeatureEvent(
            seq: entry.seq, id: entry.id, at: entry.at, steward: entry.steward, run: entry.run,
            actor: FeatureActor(
                kind: FeatureActor.Kind(rawValue: entry.actorKind) ?? .system, id: entry.actorID),
            type: entry.type, payload: payload ?? .null)
    }
}
