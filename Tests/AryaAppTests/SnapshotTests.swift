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
        // Offscreen renders run no tasks: load NOW, FINDINGS, and IMPACT's workspace reads.
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
        try page("improve") { $0.tab = .improve }
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
        // What stewards learned from Lee: his correction, kept by the triage steward.
        try page("people-learned") {
            $0.showPeople(steward: nil)
            $0.select(person: "person:lee")
        }
        // The same thread while a new hand-off's run is still going: only that message and run
        // are added, so every count and report stays the workspace's own.
        if let store = model.featureStore {
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
        // A run in progress (app-outcome): the steward the snapshot home is actually running
        // (snapshot.sh starts a lead follow-up run), with NOW read from stewardLive.
        if let live = model.liveLines.first?.steward ?? model.stewards.first?.id {
            await loadOutcomeReads(model, steward: live)
            try page("overview-live") { $0.select(steward: live) }
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
            let pages: [(String, NewStewardDraft, NewStewardDraft.Step)] = [
                ("charter-editor", NewStewardDraft.editing(live), .outcome),
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
        // A run's Diff tab (app-views): what each action writes and a routine's new version.
        let diffStore = FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now)
        await diffStore.reload()
        let diffStream = RunStream.build(events: diffStore.events, run: PreviewFixtures.finishedRun)
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
        store.outcomeReads[steward] = OutcomeReads(
            live: live, findings: findings, impact: impact ?? nil)
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
        guard Self.wanted(name, file: file) else { return }
        let png = try #require(png())
        guard let dir = ProcessInfo.processInfo.environment["ARYA_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
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
