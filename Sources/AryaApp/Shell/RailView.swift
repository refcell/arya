import Arya
import AryaDesign
import SwiftUI

/// The left rail: stewards with their runs nested under the selected one, then approvals.
struct RailView: View {
    let model: AppModel
    /// The fixed "now" used for relative times, so a render is a pure function of its inputs.
    let now: Date

    /// How many recent runs show under the selected steward.
    nonisolated static let runLimit = 5

    var body: some View {
        ScrollView { content }
            .background(AryaColor.surface)
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: move(by: -1)
                case .down: move(by: 1)
                default: break
                }
            }
            .accessibilityLabel("Stewards and approvals")
    }

    private func move(by offset: Int) {
        let items = RailOrder.items(
            stewards: model.stewards, runs: model.runs, selected: model.navigation.steward)
        let current = RailOrder.current(model.navigation)
        if let next = RailOrder.step(from: current, by: offset, in: items) {
            model.navigation.select(next)
        }
    }

    /// The rail's rows without the scroll view (renders offscreen for tests).
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            RailGroupLabel("Stewards").padding(.bottom, AryaSpace.s1)
            ForEach(model.stewards) { steward in
                stewardRows(steward)
            }
            RailGroupLabel("Approvals")
                .padding(.top, AryaSpace.s5)
                .padding(.bottom, AryaSpace.s1)
            approvalsRow
        }
        .padding(.top, AryaSpace.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func stewardRows(_ steward: StewardSummary) -> some View {
        let runs = model.runs[steward.id] ?? []
        let isSelected = model.navigation.steward == steward.id
        Button {
            model.navigation.select(steward: steward.id)
        } label: {
            RailRow(
                steward.name, status: StatusMapping.status(of: steward, runs: runs),
                isSelected: isSelected && model.navigation.run == nil)
        }
        .buttonStyle(.plain)
        if isSelected {
            ForEach(Array(runs.prefix(Self.runLimit).enumerated()), id: \.element.id) {
                index, run in
                Button {
                    model.navigation.select(run: run.id, steward: steward.id)
                } label: {
                    RailRow(
                        StatusMapping.runLabel(position: index, of: runs.count),
                        status: StatusMapping.status(of: run),
                        trailing: AryaTime.relative(run.startedAt, now: now),
                        isSelected: model.navigation.run == run.id, indent: AryaSpace.s4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var approvalsRow: some View {
        let isSelected = model.navigation.destination == .approvals
        let select = { model.navigation.showApprovals() }
        if let store = model.featureStore {
            StoreApprovalsRow(store: store, isSelected: isSelected, select: select)
        } else {
            ApprovalsRow(count: model.pendingApprovalCount, isSelected: isSelected, select: select)
        }
    }
}

/// The approvals entry with its pending count in `bodyStrong`/`accent`, hidden at zero.
struct ApprovalsRow: View {
    let count: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack {
                Text("Queue").aryaText(AryaFont.body, AryaColor.ink)
                Spacer()
                CountLabel(count, style: AryaFont.bodyStrong, color: AryaColor.accent)
            }
            .padding(.horizontal, AryaSpace.s3)
            .frame(height: AryaSize.railRowHeight)
            .background(isSelected ? AryaColor.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Approvals, \(count) pending")
    }
}

/// The approvals entry counted from the feature events, so it always matches the queue view.
struct StoreApprovalsRow: View {
    @ObservedObject var store: FeatureStore
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        ApprovalsRow(count: Self.pending(in: store), isSelected: isSelected, select: select)
    }

    static func pending(in store: FeatureStore) -> Int {
        ApprovalQueue.build(events: store.events).pending.count
    }

}
