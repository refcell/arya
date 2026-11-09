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
                    rehearse: { context.model.navigation.tab = .improve })
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
                            // One right-hand panel at a time: an event closes settings.
                            if event != nil { context.model.navigation.inspector = false }
                            context.model.navigation.ledgerEvent = event
                        }),
                    openRun: { run, steward in
                        context.model.navigation.select(run: run, steward: steward)
                    })
            } else {
                EmptyState(
                    "The ledger is empty.",
                    guidance: "Every event this steward records appears here.")
            }
        }
    }

    /// A run's transcript: the selected run, else the newest.
    @ViewBuilder
    static func transcript(_ context: FeatureContext) -> some View {
        if let store = context.store, let steward = context.steward?.id {
            StreamTab(
                store: store, steward: steward, run: context.run?.id ?? context.runs.first?.id,
                paused: context.steward?.status == .paused)
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
                created: { id in
                    model.stewardSheet = nil
                    model.navigation.select(steward: id)
                    Task { await model.refresh() }
                },
                cancel: { model.stewardSheet = nil })
        }
    }

    /// The first-launch screen when the home has no stewards.
    static func firstLaunch(_ context: FeatureContext) -> some View {
        let model = context.model
        return FirstLaunchView(
            newSteward: { model.stewardSheet = NewStewardDraft() },
            openDemo: { model.stewardSheet = .example })
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
            ApprovalQueueView(store: store)
        } else {
            Text("Nothing needs you right now.")
                .aryaText(AryaFont.body, AryaColor.inkMuted)
                .padding(AryaSpace.s5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
