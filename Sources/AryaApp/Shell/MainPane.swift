import Arya
import AryaDesign
import SwiftUI

/// The main pane on the canvas: the steward page, or the Needs you list. No header band; the
/// page starts below the traffic lights (STYLE.md Layout).
struct MainPane: View {
    let model: AppModel

    var body: some View {
        content
            // A wide feature view (the ledger table) must not widen the window and push the
            // sidebar off screen: the pane takes the space left and clips what does not fit.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .sheet(isPresented: stewardSheet) { FeatureRegistry.newSteward(model.featureContext()) }
    }

    private var stewardSheet: Binding<Bool> {
        Binding(
            get: { model.stewardSheet != nil },
            set: { if !$0 { model.stewardSheet = nil } })
    }

    @ViewBuilder private var content: some View {
        switch model.navigation.destination {
        case .approvals:
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                PageTitle(title: "Needs you", subtitle: "Approvals waiting on a person.")
                    .padding(.horizontal, AryaSize.pagePadding)
                FeatureRegistry.approvals(model.featureContext())
            }
            .padding(.top, AryaSize.titleBarInset)
        case .steward:
            if let steward = model.selectedSteward {
                StewardPage(model: model, steward: steward)
            }
        case nil:
            if model.loaded {
                FeatureRegistry.firstLaunch(model.featureContext())
                    .padding(.top, AryaSize.titleBarInset)
            }
        }
    }
}

/// A page's name and one muted sentence beneath it.
struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title).aryaText(AryaFont.title, AryaColor.ink)
                .accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty {
                Text(subtitle).aryaText(AryaFont.body, AryaColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A steward's page: name and outcome with the one primary action, an inline error when an
/// action failed, at most four tabs, then the selected tab (STYLE.md Layout).
struct StewardPage: View {
    let model: AppModel
    let steward: StewardSummary

    var body: some View {
        if let run = model.selectedRun {
            runPage(run)
        } else {
            stewardPage
        }
    }

    /// A run selected in the sidebar: a breadcrumb back to the steward, then only that run's
    /// transcript, so the screen has one purpose.
    private func runPage(_ run: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            HStack(spacing: AryaSpace.s1) {
                Button(steward.name) { model.navigation.select(steward: steward.id, showRun: nil) }
                    .buttonStyle(.aryaTertiary)
                    .accessibilityLabel("Back to \(steward.name)")
                Text("/").aryaText(AryaFont.caption, AryaColor.inkFaint)
                Text(StatusMapping.threadTitle(of: run))
                    .aryaText(AryaFont.mono, AryaColor.inkMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, AryaSize.pagePadding - AryaSpace.s3)
            if let problem = model.problem {
                InlineError(problem) { model.dismissProblem() }
                    .padding(.horizontal, AryaSize.pagePadding)
            }
            FeatureRegistry.transcript(model.featureContext())
                .frame(
                    minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, AryaSize.titleBarInset)
    }

    private var stewardPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s4) {
                PageTitle(title: steward.name, subtitle: steward.outcome)
                Spacer(minLength: AryaSpace.s4)
                primaryAction
            }
            .padding(.horizontal, AryaSize.pagePadding)
            FeatureRegistry.outcomeLine(model.featureContext())
                .padding(.horizontal, AryaSize.pagePadding)
                .padding(.top, AryaSpace.s3)
            if let problem = model.problem {
                InlineError(problem) { model.dismissProblem() }
                    .padding(.horizontal, AryaSize.pagePadding)
                    .padding(.top, AryaSpace.s2)
            }
            TextTabBar(tabs: tabs, selection: tabBinding, inset: AryaSize.pagePadding)
                .padding(.top, AryaSpace.s4)
            FeatureRegistry.view(for: model.navigation.tab, context: model.featureContext())
                .frame(
                    minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, AryaSize.titleBarInset)
    }

    /// Orange "Review N approvals" when something waits on a person, else a quiet "Run now".
    /// On Overview the approval itself is on the page with its own orange button, so the
    /// header's link goes quiet to keep one primary action per screen (STYLE.md rule 3).
    @ViewBuilder private var primaryAction: some View {
        let pending = model.pendingApprovals(steward: steward.id)
        if pending > 0 && model.navigation.tab == .overview {
            Button(StewardPage.reviewTitle(pending)) { model.navigation.showApprovals() }
                .buttonStyle(.aryaQuiet)
        } else if pending > 0 {
            Button(StewardPage.reviewTitle(pending)) { model.navigation.showApprovals() }
                .buttonStyle(.aryaPrimary)
        } else {
            Button("Run now") { Task { await model.startRun() } }
                .buttonStyle(.aryaQuiet)
                .disabled(steward.status != .active)
        }
    }

    static func reviewTitle(_ count: Int) -> String {
        count == 1 ? "Review 1 approval" : "Review \(count) approvals"
    }

    private var tabs: [TextTab<StewardTab>] {
        StewardTab.allCases.map { TextTab(id: $0, title: $0.title) }
    }

    private var tabBinding: Binding<StewardTab> {
        Binding(get: { model.navigation.tab }, set: { model.navigation.tab = $0 })
    }
}

/// The right-hand inspector, on the same canvas: steward settings (effort, pause), and the
/// app's appearance. Toggled with Option-Command-I or the sidebar's settings button.
struct InspectorView: View {
    let model: AppModel
    @AppStorage(AryaApp.appearanceKey) private var appearance = AryaAppearance.dark.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s5) {
                HStack {
                    Text("Settings").aryaText(AryaFont.heading, AryaColor.ink)
                    Spacer()
                    Button("Close") { model.navigation.inspector = false }
                        .buttonStyle(.aryaTertiary)
                }
                if let steward = model.selectedSteward {
                    section("Steward") {
                        Text(steward.name).aryaText(AryaFont.body, AryaColor.ink)
                        Text(steward.id).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    }
                    section("Effort") {
                        EffortSelector(selection: effortBinding(steward.id))
                    }
                    section("State") {
                        if steward.status == .paused {
                            Button("Resume") { Task { await model.setPaused(false) } }
                                .buttonStyle(.aryaQuiet)
                        } else {
                            Button("Pause") { Task { await model.setPaused(true) } }
                                .buttonStyle(.aryaQuiet)
                                .disabled(steward.status != .active)
                        }
                    }
                }
                section("Home") {
                    Text(model.source.label).aryaText(AryaFont.mono, AryaColor.inkMuted)
                }
                section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("Dark").tag(AryaAppearance.dark.rawValue)
                        Text("Light").tag(AryaAppearance.light.rawValue)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .onChange(of: appearance) { _, stored in
                        AryaApp.apply(AryaAppearance(stored: stored))
                    }
                }
            }
            .padding(.horizontal, AryaSpace.s4)
            .padding(.top, AryaSize.titleBarInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: AryaSize.inspectorWidth)
        .accessibilityLabel("Inspector")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text(title).aryaText(AryaFont.label, AryaColor.inkFaint)
            content()
        }
    }

    private func effortBinding(_ steward: String) -> Binding<AryaEffort> {
        Binding(
            get: { model.effort(for: steward) },
            set: { effort in Task { await model.setEffort(effort, steward: steward) } })
    }
}
