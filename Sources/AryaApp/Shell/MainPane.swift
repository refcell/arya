import Arya
import AryaDesign
import SwiftUI

/// The main pane: a steward's header, tab bar, and feature view; or the approval queue.
struct MainPane: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let problem = model.problem {
                Text(problem)
                    .aryaText(AryaFont.body, AryaColor.negative)
                    .padding(.horizontal, AryaSpace.s5)
                    .padding(.vertical, AryaSpace.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aryaHairline(edge: .bottom)
            }
            content
        }
        // A wide feature view (the ledger table) must not widen the window and push the rail
        // off screen: the pane takes the space left and clips what does not fit.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(AryaColor.canvas)
    }

    @ViewBuilder private var content: some View {
        switch model.navigation.destination {
        case .approvals:
            FeatureRegistry.approvals(model.featureContext())
        case .steward:
            if let steward = model.selectedSteward {
                StewardPane(model: model, steward: steward)
            }
        case nil:
            if model.loaded {
                EmptyState(
                    "No stewards yet.",
                    guidance: "Create one with arya steward create and it appears here.")
            }
        }
    }
}

/// A steward's header, tabs, and the selected tab's feature view.
struct StewardPane: View {
    let model: AppModel
    let steward: StewardSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(model: model, steward: steward)
            FeatureRegistry.outcomeLine(model.featureContext())
                .padding(.horizontal, AryaSpace.s5)
                .padding(.bottom, AryaSpace.s3)
            TextTabBar(tabs: tabs, selection: tabBinding, inset: AryaSpace.s5)
            FeatureRegistry.view(for: model.navigation.tab, context: model.featureContext())
                .frame(
                    minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var tabs: [TextTab<StewardTab>] {
        StewardTab.allCases.map { TextTab(id: $0, title: $0.title) }
    }

    private var tabBinding: Binding<StewardTab> {
        Binding(get: { model.navigation.tab }, set: { model.navigation.tab = $0 })
    }
}

/// Steward name in `title`, the outcome beneath, and the effort selector on the right.
struct HeaderView: View {
    let model: AppModel
    let steward: StewardSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s4) {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text(steward.name).aryaText(AryaFont.title, AryaColor.ink)
                Text(steward.outcome).aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            Spacer(minLength: AryaSpace.s4)
            EffortSelector(selection: effortBinding)
        }
        .padding(AryaSpace.s5)
    }

    private var effortBinding: Binding<AryaEffort> {
        Binding(
            get: { model.effort(for: steward.id) },
            set: { effort in Task { await model.setEffort(effort, steward: steward.id) } })
    }
}
