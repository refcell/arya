import Arya
import AryaDesign
import Foundation
import Observation

/// The app's state, read from the facade and refreshed whenever the ledger grows.
///
/// All mutation happens on the main actor. Writes go through the `WorkspaceSource`, which
/// records them as ledger events; the model then refreshes from the event that write appended.
@MainActor @Observable
final class AppModel {
    /// Whether the event stream is keeping the model current.
    enum Live: Equatable {
        case idle, watching
        /// The stream ended; the message says why. Refresh by hand until it restarts.
        case stopped(String)
    }

    let source: any WorkspaceSource
    /// The feature views' event store, when this workspace provides one.
    let featureStore: FeatureStore?
    var navigation = NavigationState()
    /// Whether the command palette (Command-K) is open.
    var paletteOpen = false
    /// The last ledger integrity check, for the status bar.
    private(set) var ledgerCheck: LedgerCheck?
    /// Whether some process serves this home's triggers; nil when the source cannot tell.
    private(set) var serving: Bool?
    /// Runs in progress (workspace `liveRuns`), re-read on every ledger change.
    var liveLines: [LiveLine] = []
    /// Why the home is served (workspace `serveState().reason`); the scheduler cell's text.
    var serveReason: String?
    /// Each steward's live state (workspace `stewardLive`): next wake, schedule, running.
    var stewardLive: [String: StewardLive] = [:]
    /// Each steward's outcome status by id (workspace `fleet()`): `on_track`, `off_track`,
    /// `no_target`, or `no_data`. The one source for "behind" (`StatusMapping.isBehind`).
    var fleetStatus: [String: String] = [:]
    /// Runs per day by steward id (workspace `runHistory`), the one source for run bars.
    var runHistory: [String: RunHistory] = [:]
    /// The whole home's runs per day (workspace `runHistory(steward: nil)`).
    var fleetHistory: RunHistory?
    /// Each steward's department by id (workspace `portfolio()`); empty when none is set.
    var departments: [String: String] = [:]
    /// Sidebar department groups folded shut.
    var collapsedDepartments: Set<String> = []
    /// Portfolio department groups folded shut.
    var collapsedPortfolioGroups: Set<String> = []
    /// The New steward flow's starting answers while its sheet is open.
    var stewardSheet: NewStewardDraft?
    private(set) var stewards: [StewardSummary] = []
    /// Runs by steward id, newest first.
    /// Set by `refresh`; snapshot tests overlay a running run to show the live state.
    var runs: [String: [RunSummary]] = [:]
    /// Pending approvals, oldest first.
    private(set) var approvals: [ApprovalSummary] = []
    private(set) var efforts: [String: AryaEffort] = [:]
    private(set) var loaded = false
    /// The last load or write error, phrased for people.
    private(set) var problem: String?
    private(set) var live: Live = .idle
    /// The next ledger sequence number the model has not yet seen.
    private(set) var nextSeq = 1
    /// How many refreshes have completed; tests and diagnostics read it.
    private(set) var refreshCount = 0
    /// Where new approvals are announced, if anywhere.
    var notifications: (any NotificationPosting)?
    @ObservationIgnored private var notifier = ApprovalNotifier()
    /// Where connection secrets are kept: the Keychain, or memory in tests and snapshots.
    @ObservationIgnored var credentials: any CredentialStore = KeychainCredentialStore()
    /// Connection test results for this session (Connections page and inspector).
    @ObservationIgnored let connectionTests = ConnectionTestStore()
    /// Report previews for this session (People's Report section).
    @ObservationIgnored let reports = ReportDigestStore()

    init(source: any WorkspaceSource, featureStore: FeatureStore? = nil) {
        self.source = source
        self.featureStore = featureStore
    }

    var pendingApprovalCount: Int { approvals.count }

    /// Pending approvals for one steward.
    func pendingApprovals(steward: String) -> Int {
        approvals.filter { $0.steward == steward }.count
    }

    /// Clears the error shown beside the action that failed.
    func dismissProblem() { problem = nil }

    var selectedSteward: StewardSummary? {
        navigation.steward.flatMap { id in stewards.first { $0.id == id } }
    }

    var selectedRun: RunSummary? {
        guard let id = navigation.run, let steward = navigation.steward else { return nil }
        return runs[steward]?.first { $0.id == id }
    }

    func effort(for steward: String) -> AryaEffort { efforts[steward] ?? .medium }

    func featureContext() -> FeatureContext {
        FeatureContext(
            model: self, steward: selectedSteward, run: selectedRun, store: featureStore,
            runs: navigation.steward.flatMap { runs[$0] } ?? [])
    }

    /// Reloads everything the shell shows. Errors become `problem`; old values stay visible.
    func refresh() async {
        do {
            let stewards = try await source.stewards()
            var runs: [String: [RunSummary]] = [:]
            for run in try await source.runs(steward: nil) {
                runs[run.steward, default: []].append(run)
            }
            let approvals = try await source.approvals(includeDecided: false)
            let efforts = try await source.efforts()
            self.stewards = stewards
            self.runs = runs
            self.approvals = approvals.sorted { $0.requestedAt < $1.requestedAt }
            self.efforts = efforts.compactMapValues(AryaEffort.init(rawValue:))
            // Integrity is a status-bar fact; a failed check leaves the last one shown.
            if let check = try? await source.verifyLedger() { ledgerCheck = check }
            let serve = await source.serveSchedule()
            featureStore?.serve = serve
            if let known = serve?.serving {
                serving = known
            } else {
                serving = await source.schedulerServing()
            }
            liveLines = await source.liveLines()
            serveReason = await source.serveReason()
            stewardLive = await source.stewardLives(stewards.map(\.id))
            fleetStatus = await source.fleetStatus()
            runHistory = await source.runHistories(stewards.map(\.id))
            fleetHistory = await source.fleetRunHistory()
            departments = await source.departments()
            problem = nil
            announce(approvals, stewards: stewards)
        } catch {
            problem = Self.describe(error)
        }
        loaded = true
        refreshCount += 1
        let selectedRuns = navigation.steward.flatMap { runs[$0] }?.map(\.id) ?? []
        navigation.reconcile(stewards: stewards.map(\.id), runs: selectedRuns)
        await preloadRunFacts()
    }

    /// The runs the shell names right now: the selected steward's rail threads, the open run,
    /// and every run going.
    var shownRunIDs: [String] {
        let rail = navigation.steward.flatMap { runs[$0] }?.prefix(RailView.runLimit) ?? []
        return rail.map(\.id) + [navigation.run].compactMap { $0 } + liveLines.map(\.run)
    }

    /// Loads workspace `runFacts` (dry run, step, decisions, tools, actions) for `ids`, or the
    /// shown runs. Finished runs load once; running ones reload. Views read the facts, never a
    /// ledger projection, and offscreen renders (which run no tasks) get them too.
    func preloadRunFacts(_ ids: [String]? = nil) async {
        guard let store = featureStore else { return }
        let going = Set(liveLines.map(\.run))
        for id in Set(ids ?? shownRunIDs) where store.runFacts[id] == nil || going.contains(id) {
            await store.loadRunFacts(id)
        }
    }

    /// A run's one title for the rail, breadcrumb, inspector, and palette.
    func title(of run: RunSummary) -> String {
        StatusMapping.threadTitle(
            of: run, dryRun: featureStore?.runFacts[run.id]?.dryRun ?? false)
    }

    /// Follows the ledger and refreshes after each new event. Returns when the stream ends or
    /// the calling task is cancelled.
    func watch() async {
        live = .watching
        do {
            for try await entry in source.events(from: nextSeq) {
                nextSeq = max(nextSeq, entry.seq + 1)
                await refresh()
            }
            live = .stopped("The ledger stream ended.")
        } catch is CancellationError {
            live = .idle
        } catch {
            live = .stopped(Self.describe(error))
        }
    }

    private func announce(_ approvals: [ApprovalSummary], stewards: [StewardSummary]) {
        let names = Dictionary(stewards.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let notices = notifier.newlyPending(approvals, stewardNames: names)
        guard let notifications else { return }
        for notice in notices { notifications.post(notice) }
    }

    /// Starts a manual run of the selected steward; the rail shows it from its first event.
    func startRun(input: String = "") async {
        guard let steward = navigation.steward else { return }
        await write { _ = try await source.startRun(steward: steward, input: input) }
    }

    /// Pauses or resumes the selected steward.
    /// Starts firing the home's triggers from this app (NOW's Start serving).
    func startServing() async {
        await write { _ = try await self.source.startServing() }
    }

    func setPaused(_ paused: Bool) async {
        guard let steward = navigation.steward else { return }
        await write {
            if paused {
                try await source.pauseSteward(steward)
            } else {
                try await source.resumeSteward(steward)
            }
        }
    }

    func approve(_ id: String) async { await write { _ = try await source.approve(id, note: nil) } }

    func deny(_ id: String) async { await write { _ = try await source.deny(id, note: nil) } }

    func setEffort(_ effort: AryaEffort, steward: String) async {
        let previous = efforts[steward]
        efforts[steward] = effort
        await write { try await source.setEffort(effort.rawValue, steward: steward) }
        if problem != nil { efforts[steward] = previous }
    }

    private func write(_ body: () async throws -> Void) async {
        do {
            try await body()
            problem = nil
        } catch {
            problem = Self.describe(error)
            return
        }
        await refresh()
    }

    /// A sentence for people: cause first, as STYLE.md asks.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as WorkspaceError:
            switch error {
            case .unavailable(let call): "This workspace cannot do that yet (\(call))."
            case .notFound(let id): "Nothing has the id \(id). It may have been removed."
            case .rejected(let detail): "The workspace refused: \(detail)."
            }
        default: "Something went wrong: \(error.localizedDescription)."
        }
    }
}
