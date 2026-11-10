import Arya
import AryaDesign
import SwiftUI

/// The seam between the shell and the feature views. The shell calls these two functions;
/// the app-views lane replaces each placeholder with its real view. Keep signatures stable.
@MainActor
enum FeatureRegistry {
    /// Two sections of a merged tab in one scrolling column: each takes its natural height
    /// (its own scroll view sized to its content), so neither clips the other.
    static func stacked(
        @ViewBuilder _ first: () -> some View, @ViewBuilder second: () -> some View
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                first().fixedSize(horizontal: false, vertical: true)
                AryaHairline()
                second().fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The view for a steward tab.
    @ViewBuilder
    static func view(for tab: StewardTab, context: FeatureContext) -> some View {
        switch tab {
        case .overview:
            if let store = context.store, let steward = context.steward?.id {
                OverviewTab(
                    store: store, steward: steward,
                    openRun: { run in context.model.navigation.select(run: run, steward: steward) },
                    openApprovals: { context.model.navigation.showApprovals() },
                    rehearse: { context.model.navigation.tab = .improve },
                    startServing: { Task { await context.model.startServing() } })
            } else {
                EmptyState(
                    "No overview yet.", guidance: "A steward's plan and activity appear here.")
            }
        case .improve:
            if let store = context.store, let steward = context.steward?.id {
                ImproveView(
                    store: store, steward: steward, paused: context.steward?.status == .paused)
            } else {
                EmptyState(
                    "Nothing to improve yet.",
                    guidance: "Rehearsals and proposed charter changes appear here.")
            }
        case .knowledge:
            if let store = context.store, let steward = context.steward?.id {
                KnowledgeTab(store: store, steward: steward)
            } else {
                EmptyState(
                    "No knowledge yet.",
                    guidance: "Notes kept between runs, and routines written after repeated work.")
            }
        case .ledger:
            if let store = context.store {
                LedgerView(
                    store: store, steward: context.steward?.id,
                    selection: Binding(
                        get: { context.model.navigation.ledgerEvent },
                        set: { event in
                            // The shell's one inspector shows the event's payload and hash.
                            if event != nil { context.model.navigation.inspector = true }
                            context.model.navigation.ledgerEvent = event
                        }),
                    openRun: { run, steward in
                        context.model.navigation.select(run: run, steward: steward)
                    },
                    inlineInspector: false)
            } else {
                EmptyState(
                    "The ledger is empty.",
                    guidance: "Every event this steward records appears here.")
            }
        }
    }

    /// Commands the feature lanes add to the palette (Command-K); the shell's own come first.
    /// Add one `PaletteCommand` per action, with its keycap when it has a shortcut.
    @MainActor
    static func commands(_ model: AppModel) -> [PaletteCommand] {
        guard let store = model.featureStore, case .loaded(let events) = store.state else {
            return []
        }
        var out: [PaletteCommand] = []
        let pending = ApprovalQueue.build(events: events).pending
        if let item = NeedsYouKeys(pending: pending, selected: model.navigation.approval).current {
            let title = item.kind == "question" ? item.summary : "\(item.kind) \(item.target)"
            let risk = NeedsYouKeys.needsConfirm(item) ? " (high risk)" : ""
            out.append(
                PaletteCommand(
                    id: "approve-\(item.id)", title: "Approve \(title)\(risk)", group: "Needs you",
                    keys: "A"
                ) { _ in Task { await store.perform(.approve(approval: item.id)) } })
            out.append(
                PaletteCommand(
                    id: "deny-\(item.id)", title: "Deny \(title)", group: "Needs you", keys: "D"
                ) {
                    _ in Task { await store.perform(.deny(approval: item.id, reason: "")) }
                })
        }
        return out
    }

    /// A ledger event's detail (payload, hash, its run) for the shell's inspector.
    @ViewBuilder
    static func eventInspector(_ context: FeatureContext, event id: String) -> some View {
        if let store = context.store, case .loaded(let events) = store.state,
            let event = events.first(where: { $0.id == id })
        {
            let table = LedgerTable.build(events: events, filter: .all)
            LedgerInspector(
                store: store, event: event, title: event.run.flatMap { table.runTitles[$0] },
                openRun: { run, steward in
                    context.model.navigation.select(run: run, steward: steward)
                }
            ) {
                context.model.navigation.ledgerEvent = nil
            }
        }
    }

    /// The inspector for a selected approval (Needs you).
    @ViewBuilder
    static func approvalInspector(_ context: FeatureContext, approval: String) -> some View {
        if let store = context.store {
            ApprovalInspector(store: store, approval: approval) { run, steward in
                context.model.navigation.select(run: run, steward: steward)
            }
        }
    }

    /// A run's transcript: the selected run, else the newest.
    @ViewBuilder
    static func transcript(_ context: FeatureContext) -> some View {
        if let store = context.store, let steward = context.steward?.id {
            StreamTab(
                store: store, steward: steward, run: context.run?.id ?? context.runs.first?.id,
                paused: context.steward?.status == .paused,
                openRun: { run in context.model.navigation.select(run: run, steward: steward) })
        } else {
            EmptyState(
                "No runs yet.",
                guidance: "A run starts when a routine fires or you start one by hand.")
        }
    }

    /// The selected steward's outcome line (KPI against target, sparkline, status, and the
    /// pane's one primary action), shown under its name above the tabs.
    @ViewBuilder
    static func outcomeLine(_ context: FeatureContext) -> some View {
        if let store = context.store, let steward = context.steward?.id {
            OutcomeLine(
                store: store, steward: steward,
                review: { context.model.navigation.showApprovals() },
                runNow: { Task { await context.model.startRun() } })
        }
    }

    /// The New steward sheet, started from `model.stewardSheet`; lands on the new steward.
    @ViewBuilder
    static func newSteward(_ context: FeatureContext) -> some View {
        let model = context.model
        if let store = context.store {
            NewStewardSheet(
                store: store, draft: model.stewardSheet ?? NewStewardDraft(),
                startsWithTemplates: (model.stewardSheet ?? NewStewardDraft()).name.isEmpty,
                created: { id in
                    let proposed = model.stewardSheet?.editing != nil
                    model.stewardSheet = nil
                    model.navigation.select(steward: id)
                    if proposed { model.navigation.tab = .improve }
                    Task { await model.refresh() }
                },
                cancel: { model.stewardSheet = nil })
        }
    }

    /// Opens the charter editor (the New steward steps, prefilled) on the selected steward's
    /// live charter; it ends in a gated proposal shown in Improve.
    static func editCharter(_ model: AppModel) {
        guard let steward = model.navigation.steward,
            let live = LiveCharter.find(
                events: model.featureContext().store?.events ?? [], steward: steward)
        else { return }
        model.stewardSheet = .editing(live)
    }

    /// The first-launch screen when the home has no stewards.
    static func firstLaunch(_ context: FeatureContext) -> some View {
        let model = context.model
        return FirstLaunchView(
            newSteward: { model.stewardSheet = NewStewardDraft() },
            openDemo: { model.stewardSheet = .example })
    }

    /// The Connections page (Settings, Go menu): systems, what they read and do, per-steward
    /// Connect and Disconnect as gated proposals, a connection test, and Keychain secrets.
    @ViewBuilder
    static func connections(_ context: FeatureContext) -> some View {
        let model = context.model
        if let store = context.store {
            ConnectionsView(
                store: store, tests: model.connectionTests, stewards: model.stewards,
                steward: model.navigation.pageSteward,
                selected: model.navigation.connection, credentials: model.credentials,
                selectSteward: { model.navigation.showConnections(steward: $0) },
                select: { model.navigation.select(connection: $0) },
                probe: connectionProbe(model))
        } else {
            EmptyState(
                "No connections yet.",
                guidance: "Connections a steward's charter binds appear here.")
        }
    }

    /// The inspector content for a connection selected on the Connections page.
    @ViewBuilder
    static func connectionInspector(_ context: FeatureContext, connection: String) -> some View {
        let model = context.model
        if let store = context.store {
            ConnectionInspector(
                store: store, tests: model.connectionTests, connection: connection,
                steward: model.navigation.pageSteward,
                stewards: model.stewards, credentials: model.credentials,
                probe: connectionProbe(model))
        }
    }

    private static func connectionProbe(_ model: AppModel)
        -> @Sendable (ConnectionsCatalog.Entry, String?) async throws -> ConnectionTest
    {
        let source = model.source
        return { entry, secret in
            try await source.probeConnection(
                command: entry.command, args: entry.args, declared: entry.declared,
                secret: secret)
        }
    }

    /// The People page (Settings, Go menu): who a steward works with, how it reaches them, and
    /// what they may approve; edits are gated proposals.
    @ViewBuilder
    static func people(_ context: FeatureContext) -> some View {
        let model = context.model
        if let store = context.store {
            PeopleView(
                store: store, stewards: model.stewards,
                steward: model.navigation.pageSteward,
                selected: model.navigation.person
                    ?? firstPerson(store, model, steward: model.navigation.pageSteward),
                selectSteward: { model.navigation.showPeople(steward: $0) },
                select: { model.navigation.select(person: $0) },
                open: { person, steward in
                    model.navigation.showPeople(steward: steward)
                    model.navigation.select(person: person)
                },
                reports: model.reports,
                readReport: { [source = model.source] in try await source.reportDigest(steward: $0)
                },
                pane: model.navigation.peoplePane,
                selectPane: { model.navigation.peoplePane = $0 },
                tests: model.connectionTests.results)
        } else {
            EmptyState("No people yet.", guidance: "The people stewards work with appear here.")
        }
    }

    /// The inspector content for a person selected on the People page: reach, approvals, and
    /// the work they handed off with its status.
    @ViewBuilder
    static func personInspector(_ context: FeatureContext, person: String) -> some View {
        let model = context.model
        if let store = context.store {
            let page = model.navigation.pageSteward
            let id = person.isEmpty ? firstPerson(store, model, steward: page) ?? "" : person
            // All stewards: the person as their first steward knows them.
            let steward =
                page
                ?? PeopleRoster(
                    events: store.events, stewards: model.stewards.map(\.id),
                    conversations: store.conversations
                )
                .people.first { $0.id == id }?.stewards.first
            if let steward {
                PersonInspector(store: store, steward: steward, person: id)
            }
        }
    }

    /// The person People shows when none is chosen: the scope's first.
    private static func firstPerson(_ store: FeatureStore, _ model: AppModel, steward: String?)
        -> String?
    {
        guard let steward else {
            return PeopleRoster(
                events: store.events, stewards: model.stewards.map(\.id),
                conversations: store.conversations
            )
            .people.first?.id
        }
        return PeopleDirectory(events: store.events, steward: steward).people.first?.id
    }

    /// Questions to person bindings across all stewards, for the rail's inbox entry.
    @ViewBuilder
    static func inbox(_ context: FeatureContext) -> some View {
        if let store = context.store {
            InboxView(store: store)
        } else {
            EmptyState(
                "No questions for people.",
                guidance: "When a steward asks a person binding something, it appears here.")
        }
    }

    /// The approval queue across all stewards.
    @ViewBuilder
    static func approvals(_ context: FeatureContext) -> some View {
        if let store = context.store {
            ApprovalQueueView(
                store: store,
                selection: Binding(
                    get: { context.model.navigation.approval },
                    set: { context.model.navigation.approval = $0 }),
                openRun: { run, steward in
                    context.model.navigation.select(run: run, steward: steward)
                })
        } else {
            Text("Nothing needs you right now.")
                .aryaText(AryaFont.body, AryaColor.inkMuted)
                .padding(AryaSpace.s4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
