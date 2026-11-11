import AppKit
import Arya
import AryaDesign
import Foundation
import SwiftUI
import Testing

@testable import AryaApp

/// Visual checks without a window (decision 0038). `just snapshot` seeds or reuses the demo
/// home, sets `ARYA_SNAPSHOT_HOME` to it and `ARYA_SNAPSHOT_DIR` to `.build/snapshots`, and
/// this suite renders every key state offscreen through `NSHostingView.cacheDisplay`: no window,
/// no Dock icon, no focus change. Without the variables it renders the fake workspace and
/// writes nothing, so the rendering itself stays under test.
@MainActor @Suite struct SnapshotTests {
    /// The snapshot size in points.
    static let size = NSSize(width: 1400, height: 1000)

    @Test(arguments: ["dark", "light"])
    func snapshots(scheme: String) async throws {
        SnapshotProgress.begin("snapshots (\(scheme))")
        defer { SnapshotProgress.end() }
        let dark = scheme == "dark"
        let model = try await makeModel()
        await model.refresh()
        await model.featureStore?.reload()
        let steward = try #require(model.stewards.first { $0.id == "st_triage" })
        let runs = model.runs[steward.id] ?? []
        let waiting = runs.first { run in model.approvals.contains { $0.run == run.id } }
        // The run page shows a run that read and acted itself, so its work pane has tool calls.
        let quiet =
            runs.first { run in
                !model.approvals.contains { $0.run == run.id } && run.trigger != "join"
            } ?? runs.first { run in !model.approvals.contains { $0.run == run.id } }

        func page(_ name: String, _ arrange: (inout NavigationState) -> Void) throws {
            guard
                Self.wanted(name, file: "\(name).png")
                    || Self.wanted(name, file: "\(name)-light.png")
            else { return }
            var navigation = NavigationState()
            navigation.select(steward: steward.id)
            arrange(&navigation)
            model.navigation = navigation
            try write(name, scheme: scheme, render(RootView(model: model), dark: dark))
        }
        // Offscreen renders run no tasks: load the runs' workspace facts (titles, inspector
        // steps and actions) and NOW, FINDINGS, and IMPACT's workspace reads.
        await model.preloadRunFacts(
            model.shownRunIDs + [quiet?.id, waiting?.id].compactMap { $0 }
                + runs.prefix(RailView.runLimit).map(\.id))
        await loadOutcomeReads(model, steward: steward.id)
        try page("overview") { $0.tab = .overview }
        // Nothing selected: the inspector lists the steward's context, Settings last.
        try page("overview-with-inspector") { $0.tab = .overview }
        try page("overview-no-inspector") { $0.inspector = false }
        model.navigation = NavigationState()
        model.navigation.select(steward: steward.id)
        try write("window", scheme: scheme, renderInWindow(RootView(model: model), dark: dark))
        if let quiet { try page("run") { $0.select(run: quiet.id, steward: steward.id) } }
        try await runWindows(model: model, scheme: scheme, dark: dark)
        if let waiting {
            try page("run-approval") { $0.select(run: waiting.id, steward: steward.id) }
        }
        try page("needs-you") { $0.showApprovals() }
        // The sidebar by department, one group folded to its header (counts, waiting, behind).
        if let folded = Set(model.departments.values).sorted().last {
            model.collapsedDepartments = [folded]
            try page("sidebar-folded") { $0.tab = .overview }
            model.collapsedDepartments = []
        }
        // Every steward in one table, sorted by need; the fleet pulse in the inspector.
        try page("portfolio") { $0.showPortfolio() }
        // Live: the real lease-held run the snapshot script started (workspace `liveRuns()`),
        // no fixture. Rail, status bar, inspector, and portfolio all read `liveLines`.
        try page("portfolio-live") { $0.showPortfolio() }
        // Command-K over the Overview: the search line, commands, groups, and keycaps.
        model.paletteOpen = true
        try page("command-palette") { $0.tab = .overview }
        model.paletteOpen = false
        // App settings, behind the gear (Command-comma), apart from any steward.
        // At the Settings window's own size, not the main window's.
        let settings = AppSettingsView(home: model.source.label)
        try write(
            "app-settings", scheme: scheme,
            render(settings, dark: dark, size: AppSettingsView.windowSize))
        // The fleet in the sidebar: another steward selected, so every steward's dot, the
        // paused word, and the selected one's metric against its target all show.
        if let other = model.stewards.first(where: { $0.id != steward.id && $0.status == .active })
        {
            try page("stewards") { $0.select(steward: other.id) }
        }
        if Self.wanted("needs-you-autonomy", file: "") {
            let autonomy = await autonomyModel()
            try write(
                "needs-you-autonomy", scheme: scheme, render(RootView(model: autonomy), dark: dark))
        }
        if let store = model.featureStore {
            // The review queue is an async read; load it before drawing Improve.
            store.reviewQueues[steward.id] = try? await store.workspace.reviewQueue(
                steward: steward.id)
            store.learnedChecks[steward.id] = try? await store.workspace.learnedChecks(
                steward: steward.id)
        }
        // Improve at 1280 x 800 (the dead-space bar): its reads load first, as `.task` would.
        if let store = model.featureStore, Self.wanted("improve", file: "improve.png") {
            store.reviewQueues[steward.id] = try? await store.workspace.reviewQueue(
                steward: steward.id)
            store.learnedChecks[steward.id] = try? await store.workspace.learnedChecks(
                steward: steward.id)
            store.trajectories[steward.id] = try? await store.workspace.trajectories(
                steward: steward.id)
            var navigation = NavigationState()
            navigation.select(steward: steward.id)
            navigation.tab = .improve
            model.navigation = navigation
            let laptop = CGSize(width: 1280, height: 800)
            try write(
                "improve", scheme: scheme,
                render(RootView(model: model), dark: dark, size: laptop))
        }
        // Improve's proposals: one whose rehearsal regressed and one that passed (app-outcome).
        if let store = model.featureContext().store,
            let live = LiveCharter.find(events: store.events, steward: steward.id)?.charter
        {
            let events =
                store.events
                + ProposalFixtures.events(live: live, steward: steward.id, start: store.now)
            let section = OutcomeProposalsSection(
                store: store, list: ChangeList.build(events: events, steward: steward.id),
                events: events, latestRun: nil
            )
            .padding(AryaSpace.s5)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(AryaColor.canvas)
            try write("improve-proposals", scheme: scheme, render(section, dark: dark))
            // The demo's own proposal (guardrail, adapter, and rule notes) with its whole diff.
            let tall = CGSize(width: Self.size.width, height: 2000)
            let demo = OutcomeProposalsSection(
                store: store, list: ChangeList.build(events: store.events, steward: steward.id),
                events: store.events, latestRun: nil
            )
            .padding(AryaSpace.s5)
            .frame(width: tall.width, height: tall.height, alignment: .topLeading)
            .background(AryaColor.canvas)
            try write(
                "improve-proposal-full", scheme: scheme, render(demo, dark: dark, size: tall))
        }
        // What worked (eval) from the seeded follow-up checks, and the go-live gate card
        // onboarding embeds; both are the steward's real reads.
        if let store = model.featureStore,
            let worked = try? await store.workspace.trajectories(steward: steward.id)
        {
            let wide = CGSize(width: Self.size.width, height: 420)
            try write(
                "improve-trajectories", scheme: scheme,
                render(
                    Self.card(WhatWorkedPanel(trajectories: worked), wide), dark: dark, size: wide))
            if let gate = try? await store.workspace.goLiveGate(steward: steward.id) {
                let short = CGSize(width: Self.size.width, height: 200)
                try write(
                    "onboarding-gate", scheme: scheme,
                    render(Self.card(GoLiveGateRow(gate: gate), short), dark: dark, size: short))
            }
        }
        // Offscreen renders run no tasks, so load what the Knowledge tab would.
        if let store = model.featureStore {
            store.knowledge[steward.id] = try? await store.workspace.knowledge(steward: steward.id)
        }
        try page("knowledge") { $0.tab = .knowledge }
        // The event inspector for a selected ledger row joins this set when app-views ships it.
        try page("ledger") { $0.tab = .ledger }
        if case .loaded(let events) = model.featureStore?.state,
            let event = events.last(where: { $0.steward == steward.id })
        {
            // The inspector's hash and prev come from an async read; load it before drawing.
            await model.featureStore?.loadEventDetail(seq: event.seq)
            try page("ledger-inspector") {
                $0.tab = .ledger
                $0.ledgerEvent = event.id
            }
        }
        try page("settings") { $0.inspector = true }
        // The steward's Details disclosure, open: schedule line, readiness, autonomy.
        if let store = model.featureContext().store {
            let state = OutcomeState.build(
                events: store.events, steward: steward.id, now: store.now)
            let details = OutcomeDetails(state: state, now: store.now, open: true)
                .padding(AryaSpace.s6)
                .frame(width: 560, alignment: .topLeading)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                .background(AryaColor.canvas)
            try write("details", scheme: scheme, render(details, dark: dark))
        }
        // Connections: secrets come from memory, never the Keychain, in tests (connect lane).
        model.credentials = MemoryCredentialStore(["inbox": "demo-secret"])
        try page("connections") {
            $0.showConnections()
            $0.inspector = false
        }
        // A steward missing a connection: Connect is the page's one primary action.
        if let digest = model.stewards.first(where: { $0.id == "st_digest" }) {
            try page("connections-connect") {
                $0.showConnections(steward: digest.id)
                $0.inspector = false
            }
        }
        // A tested connection selected: the inspector follows it.
        model.connectionTests.results["inbox"] = ConnectionTest(
            ok: true, server: "inbox-mcp", tools: ["search", "get", "label", "route", "reply"],
            latencyMilliseconds: 14)
        try page("connections-inspector") {
            $0.showConnections()
            $0.select(connection: "inbox")
        }
        // The catalog at density with a tested connection's detail: reads, actions by risk,
        // stewards, recent calls, and the secret (connect lane).
        try page("connections-detail") {
            $0.showConnections(steward: steward.id)
            $0.select(connection: "inbox")
        }
        // Offscreen renders run no tasks, so load the Report section's digest first.
        model.reports.digests[steward.id] = try? await model.source.reportDigest(
            steward: steward.id)
        try page("people") { $0.showPeople() }
        // Sam's conversation on the demo home (connect lane): seeded asks, a correction, hand-offs
        // with their runs, and the weekly report, all from the workspace.
        try page("people-thread") {
            $0.showPeople(steward: steward.id)
            $0.select(person: "person:sam")
        }
        // The channels people use: the local inbox and the chat relay, with volume.
        model.connectionTests.results["chat"] = ConnectionTest(
            ok: true, server: "chat-mcp", tools: ["receive", "send"], latencyMilliseconds: 9)
        try page("people-channels") {
            $0.showPeople(steward: steward.id)
            $0.peoplePane = .channels
        }
        // Reports: cadence, next and last send, the next report from the real digest, Send now,
        // and past reports with each recipient's delivery.
        model.reports.digests[steward.id] = try? await model.source.reportDigest(
            steward: steward.id)
        try page("reports") {
            $0.showPeople(steward: steward.id)
            $0.peoplePane = .reports
        }
        // The Routines library (connect): every routine across stewards, the selected one's
        // stewards, newest diff, and Use in steward…; the diff is loaded as a selection would.
        if let store = model.featureStore,
            let first = RoutineLibrary(events: store.events, now: store.now).entries
                .max(by: { $0.uses.count < $1.uses.count })
        {
            await store.loadLibraryDiff(first)
            try page("routines-library") {
                $0.showRoutines()
                $0.select(routine: first.name)
            }
        }
        // A crew run fanning out (connect): the host and four delegates in the run inspector,
        // one done, two working, one refused; only the crew run's events are added to the home.
        if Self.wanted("crew-fanout-live", file: "crew-fanout-live.png"),
            let store = model.featureStore
        {
            let base = store.events.map(\.seq).max() ?? 0
            let fan = CrewFanoutFixtures.live(now: store.now, steward: steward.id).map {
                var event = $0
                event.seq += base
                return event
            }
            let fanStore = FeatureStore(
                workspace: PreviewWorkspace(events: store.events + fan, now: store.now),
                now: store.now)
            await fanStore.reload()
            let fanModel = AppModel(source: model.source, featureStore: fanStore)
            await fanModel.refresh()
            fanModel.runs[steward.id, default: []].insert(
                RunSummary(
                    id: CrewFanoutFixtures.host, steward: steward.id, trigger: "message",
                    charterVersion: 1, status: .running,
                    startedAt: store.now.addingTimeInterval(-90)), at: 0)
            var navigation = NavigationState()
            navigation.select(run: CrewFanoutFixtures.host, steward: steward.id)
            fanModel.navigation = navigation
            try write(
                "crew-fanout-live", scheme: scheme, render(RootView(model: fanModel), dark: dark))
        }
        // What stewards learned from Lee: his correction, kept by the triage steward.
        try page("people-learned") {
            $0.showPeople(steward: nil)
            $0.select(person: "person:lee")
        }
        // The same thread while a new hand-off's run is still going: only that message and run
        // are added, so every count and report stays the workspace's own.
        if let store = model.featureStore, Self.wants("people-thread-live") {
            let setup = SnapshotWatchdog("people-thread-live (setup)")
            defer { setup.cancel() }
            let base = store.events.map(\.seq).max() ?? 0
            let live = PeopleFixtures.live(
                steward: steward.id, person: "person:sam", start: store.now.addingTimeInterval(-90)
            ).map {
                var event = $0
                event.seq += base
                return event
            }
            let liveStore = FeatureStore(
                workspace: PreviewWorkspace(events: store.events + live, now: store.now),
                now: store.now)
            await liveStore.reload()
            let liveModel = AppModel(source: model.source, featureStore: liveStore)
            await liveModel.refresh()
            liveModel.reports.digests = model.reports.digests
            var navigation = NavigationState()
            navigation.showPeople(steward: steward.id)
            navigation.select(person: "person:sam")
            liveModel.navigation = navigation
            try write(
                "people-thread-live", scheme: scheme, render(RootView(model: liveModel), dark: dark)
            )
        }
        // Getting to know your team (app-outcome): a new steward with imported history and
        // the review queue open, over a preview home (the demo's stewards are all live).
        if Self.wanted("onboarding", file: "") {
            let events = onboardingEvents()
            let store = FeatureStore(
                workspace: PreviewWorkspace(events: events, now: FeatureTestClock.now),
                now: FeatureTestClock.now)
            await store.reload()
            store.reviewQueues["st_new"] = onboardingQueue(total: 40, reviewed: 12)
            store.outcomeReads["st_new"] = OutcomeReads(
                onboarding: onboardingRead(
                    done: ["systems", "people", "processes", "notes", "history"],
                    notes: onboardingNotes))
            try write(
                "onboarding", scheme: scheme,
                render(
                    OverviewTab(
                        store: store, steward: "st_new", openRun: { _ in },
                        openApprovals: {}, rehearse: {}
                    )
                    .padding(AryaSpace.s4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(AryaColor.canvas),
                    dark: dark))
        }
        // A run in progress (app-outcome): the steward the snapshot home is actually running
        // (snapshot.sh starts a lead follow-up run), with NOW read from stewardLive.
        // Its own fresh model, so nothing an earlier page left on the shared one carries over,
        // and no setup at all when the filter leaves it out.
        if Self.wants("overview-live") {
            let setup = SnapshotWatchdog("overview-live (setup)")
            let fresh = try await makeModel()
            await fresh.refresh()
            await fresh.featureStore?.reload()
            if let live = fresh.liveLines.first?.steward ?? fresh.stewards.first?.id {
                await loadOutcomeReads(fresh, steward: live)
                setup.cancel()
                fresh.navigation.select(steward: live)
                try write(
                    "overview-live", scheme: scheme, render(RootView(model: fresh), dark: dark))
            }
            setup.cancel()
        }
        // Sheets do not draw offscreen, so the New steward flow renders as its own page.
        model.navigation = NavigationState()
        model.navigation.select(steward: steward.id)
        let sheet = FeatureRegistry.newSteward(model.featureContext())
            .frame(width: AryaSize.newStewardWidth, height: 640, alignment: .top)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(AryaColor.canvas)
        try write("new-steward", scheme: scheme, render(sheet, dark: dark))
        // Steps 2-5 of the flow, filled with the example (app-outcome).
        if let store = model.featureContext().store {
            for step in NewStewardDraft.Step.allCases.dropFirst() {
                let page = NewStewardSheet(
                    store: store, draft: .example, step: step, created: { _ in }, cancel: {}
                )
                .frame(width: AryaSize.newStewardWidth, height: 640, alignment: .top)
                .frame(width: Self.size.width, height: Self.size.height)
                .background(AryaColor.canvas)
                try write(
                    "new-steward-\(step.rawValue + 1)", scheme: scheme, render(page, dark: dark))
            }
        }
        // The charter editor: the same steps on the live charter, ending in a proposal.
        if let store = model.featureContext().store,
            let live = LiveCharter.find(events: store.events, steward: steward.id)
        {
            var edit = NewStewardDraft.editing(live)
            edit.outcome += " Security reports reach the security queue within 15 minutes."
            edit.whyChange = "Security reports were waiting behind billing questions."
            var metrics = NewStewardDraft.editing(live)
            metrics.owner = "person:maya"
            metrics.addGuardrailMetric()
            metrics.guardrailMetrics[0].name = "reopen_rate"
            metrics.guardrailMetrics[0].target = "0.05"
            let pages: [(String, NewStewardDraft, NewStewardDraft.Step)] = [
                ("charter-editor", NewStewardDraft.editing(live), .outcome),
                ("charter-editor-2", metrics, .metric),
                ("charter-editor-5", edit, .schedule),
            ]
            for (name, draft, step) in pages {
                let page = NewStewardSheet(
                    store: store, draft: draft, step: step, created: { _ in }, cancel: {}
                )
                .frame(width: AryaSize.newStewardWidth, height: 640, alignment: .top)
                .frame(width: Self.size.width, height: Self.size.height)
                .background(AryaColor.canvas)
                try write(name, scheme: scheme, render(page, dark: dark))
            }
        }

        // A run that delegated to a crew child (app-views): the child line expanded inline.
        let now = FakeWorkspaceSource.referenceDate
        let crewStore = FeatureStore(
            workspace: PreviewWorkspace(events: PreviewFixtures.crew(now: now), now: now),
            now: now)
        await crewStore.reload()
        let crew = RunStreamView(store: crewStore, run: PreviewFixtures.crewRun)
            .environment(\.crewOpenByDefault, true)
            .padding(AryaSpace.s5)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(AryaColor.canvas)
        try write("run-crew", scheme: scheme, render(crew, dark: dark))
        // A run in progress (app-views): spinner on the open tool call, progress, caret.
        let liveStore = FeatureStore(
            workspace: PreviewWorkspace(events: PreviewFixtures.live(now: now), now: now),
            now: now)
        await liveStore.reload()
        let live = RunStreamView(store: liveStore, run: PreviewFixtures.inProgressRun)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(AryaColor.canvas)
        try write("run-live", scheme: scheme, render(live, dark: dark))
        // A short run (app-views): the brief above the thread fills the pane: who started it,
        // the steps ticked so far and those expected, what it read.
        let short = RunStreamView(store: liveStore, run: PreviewFixtures.inProgressRun)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(AryaColor.canvas)
        try write("run-short", scheme: scheme, render(short, dark: dark))
        // A finished run checked later (app-views): resolved and reopened inline, a refused
        // step in red with its reason.
        let checkedStore = FeatureStore(
            workspace: PreviewWorkspace(events: PreviewFixtures.checked(now: now), now: now),
            now: now)
        await checkedStore.reload()
        let checked = RunStreamView(store: checkedStore, run: PreviewFixtures.checkedRun)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(AryaColor.canvas)
        try write("run-checks", scheme: scheme, render(checked, dark: dark))
        let liveOutput = RunStreamView(
            store: liveStore, run: PreviewFixtures.inProgressRun, initialTab: .output
        )
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(AryaColor.canvas)
        try write("run-live-output", scheme: scheme, render(liveOutput, dark: dark))
        let liveDiff = RunStreamView(
            store: liveStore, run: PreviewFixtures.inProgressRun, initialTab: .diff
        )
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(AryaColor.canvas)
        try write("run-live-diff", scheme: scheme, render(liveDiff, dark: dark))
        // A run streaming now (app-views): the reply arriving token by token, a shell call
        // still printing with its elapsed time, the finished one folded to a line.
        let streamStore = FeatureStore(
            workspace: PreviewWorkspace(events: PreviewFixtures.streaming(now: now), now: now),
            now: now)
        await streamStore.reload()
        let streaming = RunStreamView(
            store: streamStore, run: PreviewFixtures.streamingRun, initialTab: .output
        )
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(AryaColor.canvas)
        try write("run-streaming", scheme: scheme, render(streaming, dark: dark))
        // A run's Diff tab (app-views): what each action writes and a routine's new version.
        let diffStore = FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now)
        await diffStore.reload()
        let diffStream = RunStream.build(events: diffStore.events, run: PreviewFixtures.finishedRun)
        // The run pane driven by keys (app-views): j moved to the label action, ↵ opened its
        // diff; the hint chips name the keys.
        if let labeled = diffStream.steps.first(where: {
            if case .action = $0.kind { return true }
            return false
        }) {
            for diff in RunWork.build(stream: diffStream, events: diffStore.events).diffs {
                await diffStore.loadRoutineDiff(diff)
            }
            let keys = RunStreamView(
                store: diffStore, run: PreviewFixtures.finishedRun, initialTab: .diff,
                initialSelection: labeled.id
            )
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(AryaColor.canvas)
            try write("run-keys", scheme: scheme, render(keys, dark: dark))
        }
        for diff in RunWork.build(stream: diffStream, events: diffStore.events).diffs {
            await diffStore.loadRoutineDiff(diff)
        }
        let diffPage = RunStreamView(
            store: diffStore, run: PreviewFixtures.finishedRun, initialTab: .diff
        )
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(AryaColor.canvas)
        try write("run-diff", scheme: scheme, render(diffPage, dark: dark))

        let empty = try await emptyModel()
        defer { try? FileManager.default.removeItem(at: empty.home) }
        await empty.model.refresh()
        try write("first-launch", scheme: scheme, render(RootView(model: empty.model), dark: dark))
    }

    /// The Overview's workspace reads, as its task would load them on screen.
    func loadOutcomeReads(_ model: AppModel, steward: String) async {
        guard let store = model.featureStore else { return }
        let live = try? await store.workspace.stewardLive(steward: steward)
        let findings = try? await store.workspace.overviewFindings(steward: steward)
        let impact = try? await store.workspace.impact(steward: steward)
        let metrics = try? await store.workspace.metricStatuses(
            steward: steward, windows: OutcomeMetrics.seriesDays)
        store.outcomeReads[steward] = OutcomeReads(
            live: live, findings: findings, impact: impact ?? nil, metrics: metrics)
    }

    /// The seeded demo home when `ARYA_SNAPSHOT_HOME` is set, else the fake workspace.
    /// Full-window run states (app-views): the newest live run, and a run with a routine
    /// diff on its Diff tab, with the rail, inspector, and status bar around them.
    private func runWindows(model: AppModel, scheme: String, dark: Bool) async throws {
        guard let store = model.featureStore else { return }
        let all = model.runs.values.flatMap { $0 }
        func window(_ name: String, run: RunSummary, tab: WorkTab?) async throws {
            // Offscreen renders run no `.task`, so the workspace's numbers load first.
            await store.loadRunFacts(run.id)
            var navigation = NavigationState()
            navigation.select(steward: run.steward)
            navigation.select(run: run.id, steward: run.steward)
            model.navigation = navigation
            let root = RootView(model: model).environment(\.initialWorkTab, tab)
            try write(name, scheme: scheme, render(root, dark: dark))
        }
        if let live = all.filter({ $0.status == .running }).max(by: { $0.startedAt < $1.startedAt })
        {
            try await window("run-live-window", run: live, tab: nil)
        }
        let routineRuns = Set(
            store.events.filter { $0.type == "routine.proposed" }.compactMap(\.run))
        if let diffRun = all.first(where: { routineRuns.contains($0.id) }) {
            let stream = RunStream.build(events: store.events, run: diffRun.id)
            for diff in RunWork.build(stream: stream, events: store.events).diffs {
                await store.loadRoutineDiff(diff)
            }
            try await window("run-diff-window", run: diffRun, tab: .diff)
        }
    }

    private func makeModel() async throws -> AppModel {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["ARYA_SNAPSHOT_HOME"] {
            let workspace = try await Workspace.open(
                home: URL(fileURLWithPath: path, isDirectory: true), environment: environment)
            return AppModel(
                source: workspace,
                featureStore: FeatureStore(workspace: FacadeFeatureWorkspace(source: workspace)))
        }
        let now = FakeWorkspaceSource.referenceDate
        return AppModel(
            source: FakeWorkspaceSource(now: now),
            featureStore: FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now))
    }

    /// A steward at `suggest` autonomy with one low-risk label held for approval because of
    /// that level, not a charter rule (decision 0037: reason `autonomy:suggest:low`), shown on
    /// the Needs you page so the autonomy explanation can be judged.
    /// The facade's words for this hold (`Workspace.policyText` and `change`), copied verbatim
    /// because the preview workspace has no facade behind it.
    private static let autonomyTexts = [
        "apv_0100": FeatureApprovalText(
            policy: "This steward only suggests changes, so a person approves each action.",
            change: "label: none → billing")
    ]

    private func autonomyModel() async -> AppModel {
        let now = FakeWorkspaceSource.referenceDate
        var log = FeatureEventBuilder(start: now.addingTimeInterval(-600))
        var charter = PreviewFixtures.charter
        if case .object(var members) = charter {
            members["autonomy"] = "suggest"
            charter = .object(members)
        }
        log.add("steward.created", actor: .localUser, ["charter": charter, "version": 1])
        let run = "run_0100"
        log.add("run.started", run: run, ["trigger": "interval"])
        let action: FeatureJSON = [
            "id": "a9", "kind": "label", "target": "inbox:MSG-301",
            "rationale": "Asks about a charge on the card, so billing.", "risk": "low",
            "params": ["label": "billing"],
        ]
        log.add(
            "action.proposed", run: run,
            [
                "action": action, "disposition": "ask", "reason": "autonomy:suggest:low",
                "risk": "low", "autonomy": "suggest",
            ])
        log.add(
            "approval.requested", run: run,
            ["approval": "apv_0100", "kind": "action", "action": action, "to": "local"])
        let model = AppModel(
            source: FakeWorkspaceSource(now: now),
            featureStore: FeatureStore(
                workspace: PreviewWorkspace(
                    events: log.events, now: now, approvalTexts: Self.autonomyTexts),
                now: now))
        await model.refresh()
        await model.featureStore?.reload()
        model.navigation.showApprovals()
        return model
    }

    /// A fresh, empty home in the temp directory, for the first-launch state.
    private func emptyModel() async throws -> (model: AppModel, home: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-snapshot-\(UUID().uuidString)", isDirectory: true)
        let workspace = try await Workspace.open(home: home)
        let model = AppModel(
            source: workspace,
            featureStore: FeatureStore(workspace: FacadeFeatureWorkspace(source: workspace)))
        return (model, home)
    }

    /// Writes `<name>.png` (dark) or `<name>-light.png` when `ARYA_SNAPSHOT_DIR` is set. With
    /// `ARYA_SNAPSHOT_STATES` (comma or space separated names, `just snapshot <state>...`) only
    /// those states render: a bare name renders both schemes, `<name>-light` only the light one.
    private func write(_ name: String, scheme: String, _ png: @autoclosure () -> Data?) throws {
        let file = scheme == "dark" ? "\(name).png" : "\(name)-light.png"
        SnapshotProgress.passed(file)
        guard Self.wanted(name, file: file) else { return }
        let watchdog = SnapshotWatchdog(file)
        defer { watchdog.cancel() }
        let png = try #require(png())
        guard let dir = ProcessInfo.processInfo.environment["ARYA_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        SnapshotSpace.report(name, file: file, png: png, dir: dir)
    }

    /// A panel on the canvas at `size`, padded like a pane.
    static func card(_ view: some View, _ size: CGSize) -> some View {
        view.padding(AryaSpace.s5)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(AryaColor.canvas)
    }

    /// True when the filter keeps `state` in either scheme; gates a state's setup.
    static func wants(_ state: String) -> Bool {
        wanted(state, file: "\(state).png") || wanted(state, file: "\(state)-light.png")
    }

    /// True when no state filter is set, or the filter names this state or file.
    static func wanted(_ name: String, file: String) -> Bool {
        let raw = ProcessInfo.processInfo.environment["ARYA_SNAPSHOT_STATES"] ?? ""
        let names = raw.split { $0 == "," || $0 == " " }.map(String.init)
        guard !names.isEmpty else { return true }
        let stem = String(file.dropLast(4))
        return names.contains(name) || names.contains(stem)
    }

    /// PNG bytes of the view inside a real window frame with the app's chrome (transparent
    /// title bar, full-size content, traffic lights), so the title-bar rule can be judged. The
    /// window is never ordered on screen and the process may not activate, so nothing appears.
    private func renderInWindow(_ view: some View, dark: Bool) -> Data? {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = AryaColorToken.canvas.nsColor
        window.contentView = NSHostingView(
            rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        guard let frame = window.contentView?.superview else { return nil }
        frame.layoutSubtreeIfNeeded()
        guard let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
            return nil
        }
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// PNG bytes of a view at `size`, drawn through AppKit so scroll views render too.
    private func render(_ view: some View, dark: Bool, size: CGSize = Self.size) -> Data? {
        // Still frames only: no implicit animations in a snapshot (motion is frozen too).
        let still = view.environment(\.colorScheme, dark ? .dark : .light)
            .transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: still)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// How much of a state is blank, one number for the reviewer and every lane (STYLE.md "Dead
/// space"). Every full state renders the whole window at 1400 x 1000 pt (2800 x 2000 px); a
/// different size fails unless the state is a named component part. A pixel is blank when its
/// luminance is within 3% of the background (the most common luminance) or it lies in a uniform
/// run of 32 pt or more across or down (hairlines, blank fills). The share is of 24 pt blocks
/// (one row) with no content pixel in them.
enum SnapshotSpace {
    static let pixels = (width: 2800, height: 2000)
    /// Component crops at their own size; they report no empty share.
    static let parts: Set<String> = [
        "app-settings", "governance-settings", "improve-proposal-full", "improve-trajectories",
        "onboarding-gate",
        "governance-policy", "governance-retention", "governance-run-controls",
        "run-controls-dry-run",
    ]

    /// Sampled once per point (every other pixel at 2x); `block` and `run` are in points.
    static func emptyFraction(
        _ png: Data, tolerance: Double = 0.03, run: Int = 32, block: Int = 24
    ) -> Double? {
        guard let bitmap = NSBitmapImageRep(data: png), let data = bitmap.bitmapData,
            bitmap.bitsPerSample == 8, bitmap.samplesPerPixel >= 3
        else { return nil }
        let width = bitmap.pixelsWide / 2
        let height = bitmap.pixelsHigh / 2
        let row = bitmap.bytesPerRow * 2
        let step = bitmap.bitsPerPixel / 8 * 2
        var luma = [Double](repeating: 0, count: width * height)
        var histogram = [Int](repeating: 0, count: 256)
        for y in 0..<height {
            for x in 0..<width {
                let at = y * row + x * step
                let value =
                    (0.2126 * Double(data[at]) + 0.7152 * Double(data[at + 1])
                        + 0.0722 * Double(data[at + 2])) / 255
                luma[y * width + x] = value
                histogram[min(255, Int(value * 255))] += 1
            }
        }
        let background = Double(histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0) / 255
        var blank = luma.map { abs($0 - background) <= tolerance }
        // Long uniform runs: hairlines and blank fills carry no content.
        func mark(_ indices: [Int]) {
            var start = 0
            for k in 1...indices.count {
                let ends =
                    k == indices.count || abs(luma[indices[k]] - luma[indices[start]]) > 0.004
                if ends {
                    if k - start >= run { for m in start..<k { blank[indices[m]] = true } }
                    start = k
                }
            }
        }
        for y in 0..<height { mark(Array((y * width)..<(y * width + width))) }
        for x in 0..<width { mark(Array(stride(from: x, to: width * height, by: width))) }
        // A block (one row tall) is empty when nothing in it is content.
        var empty = 0
        var total = 0
        for top in stride(from: 0, to: height - block + 1, by: block) {
            for left in stride(from: 0, to: width - block + 1, by: block) {
                total += 1
                var clear = true
                scan: for y in top..<(top + block) {
                    for x in left..<(left + block) where !blank[y * width + x] {
                        clear = false
                        break scan
                    }
                }
                if clear { empty += 1 }
            }
        }
        return total == 0 ? nil : Double(empty) / Double(total)
    }

    /// Checks the size and records the empty share in `empty.tsv`, one row per file.
    static func report(_ name: String, file: String, png: Data, dir: String) {
        guard let bitmap = NSBitmapImageRep(data: png) else { return }
        let full = bitmap.pixelsWide == pixels.width && bitmap.pixelsHigh == pixels.height
        guard full else {
            if !parts.contains(name) {
                let size = "\(bitmap.pixelsWide) x \(bitmap.pixelsHigh) px"
                Issue.record(
                    Comment(
                        rawValue: "snapshot state \(name) is \(size); every state renders the"
                            + " whole window at 1400 x 1000 pt"))
            }
            return
        }
        guard let fraction = emptyFraction(png) else { return }
        let percent = Int((fraction * 100).rounded())
        print("empty \(file): \(percent)%")
        lock.withLock {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("empty.tsv")
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var rows = old.split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("\(file)\t") }
            rows.append("\(file)\t\(percent)")
            try? (rows.sorted().joined(separator: "\n") + "\n").write(
                to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let lock = NSLock()
}

/// One watchdog over every state's setup and render: each state that finishes re-arms it, so
/// any state (its setup included) that takes 60 s stops the run and is named by the state
/// before it. Counts the running snapshot tests and stands down when the last one ends.
enum SnapshotProgress {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = 0
    nonisolated(unsafe) private static var current: SnapshotWatchdog?

    static func begin(_ test: String) {
        lock.withLock { active += 1 }
        passed(test)
    }

    static func passed(_ state: String) {
        lock.withLock {
            current?.cancel()
            current = active > 0 ? SnapshotWatchdog("after \(state)") : nil
        }
    }

    static func end() {
        lock.withLock {
            active -= 1
            if active == 0 {
                current?.cancel()
                current = nil
            }
        }
    }
}

/// Fails a snapshot run fast when one state hangs: after `seconds` it names the state on
/// standard error and exits the test process, so `just snapshot` never spins for minutes.
final class SnapshotWatchdog: @unchecked Sendable {
    private let item: DispatchWorkItem

    init(_ state: String, seconds: Double = 60) {
        item = DispatchWorkItem {
            let text = "snapshot state \(state) did not finish in \(Int(seconds)) s; stopping\n"
            FileHandle.standardError.write(Data(text.utf8))
            // Where it spins: a 3 s stack sample next to the PNGs, for the fix.
            if let dir = ProcessInfo.processInfo.environment["ARYA_SNAPSHOT_DIR"] {
                let name = state.filter { $0.isLetter || $0.isNumber || $0 == "-" }
                let sample = Process()
                sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sample.arguments = [
                    "\(ProcessInfo.processInfo.processIdentifier)", "3", "-file",
                    "\(dir)/hang-\(name).txt",
                ]
                try? sample.run()
                sample.waitUntilExit()
            }
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() { item.cancel() }
}
