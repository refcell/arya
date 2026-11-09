import Arya
import AryaDesign
import SwiftUI

/// The sidebar: stewards with their runs as threads under the selected one (STYLE.md).
struct RailView: View {
    let model: AppModel
    /// The fixed "now" used for relative times, so a render is a pure function of its inputs.
    let now: Date

    /// How many recent runs show under the selected steward.
    nonisolated static let runLimit = 5

    var body: some View {
        ScrollView { content }
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

    /// The sidebar's rows without the scroll view (renders offscreen for tests): the
    /// wordmark, a "Needs you" row while approvals wait, then stewards with their runs as
    /// threads under the selected one (STYLE.md Layout).
    var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AryaSpace.s2) {
                Text("arya").aryaText(AryaFont.monoStrong, AryaColor.ink)
                Spacer(minLength: 0)
                Button {
                    model.stewardSheet = NewStewardDraft()
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.aryaTertiary)
                .foregroundStyle(AryaColor.inkMuted)
                .help("New steward")
                .accessibilityLabel("New steward")
            }
            .padding(.horizontal, AryaSpace.s2)
            .frame(height: AryaSize.rowHeight)
            .padding(.bottom, AryaSpace.s3)
            needsYouRow
            if !model.stewards.isEmpty {
                RailGroupLabel("Stewards")
                    .padding(.bottom, AryaSpace.s1)
            }
            ForEach(model.stewards) { steward in
                stewardRows(steward)
            }
        }
        .padding(.horizontal, AryaSpace.s2)
        .padding(.top, AryaSize.titleBarInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The steward's metric series from the ledger, when the feature store has loaded it.
    private func metric(_ steward: String) -> MetricSeries? {
        guard case .loaded(let events) = model.featureStore?.state else { return nil }
        return MetricSeries.build(events: events, steward: steward)
    }

    @ViewBuilder private func stewardRows(_ steward: StewardSummary) -> some View {
        let runs = model.runs[steward.id] ?? []
        let isSelected = model.navigation.steward == steward.id
        Button {
            model.navigation.select(steward: steward.id)
        } label: {
            let series = metric(steward.id)
            RailRow(
                steward.name,
                status: StatusMapping.health(
                    of: steward, runs: runs, pending: model.pendingApprovals(steward: steward.id),
                    onTrack: series?.meetsTarget),
                trailing: steward.status == .paused
                    ? "paused"
                    : isSelected
                        ? StatusMapping.metricSuffix(
                            latest: series?.latest?.value, target: series?.definition.target)
                        : nil,
                isSelected: isSelected && model.navigation.run == nil
                    && model.navigation.destination != .approvals,
                trailingIsMono: steward.status != .paused)
        }
        .buttonStyle(.plain)
        if isSelected {
            ForEach(runs.prefix(Self.runLimit)) { run in
                Button {
                    model.navigation.select(run: run.id, steward: steward.id)
                } label: {
                    ThreadRow(
                        StatusMapping.threadTitle(of: run),
                        time: ThreadRow.shortTime(run.startedAt, now: now),
                        needsYou: model.approvals.contains { $0.run == run.id },
                        isSelected: model.navigation.run == run.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var needsYouRow: some View {
        let isSelected = model.navigation.destination == .approvals
        let select = { model.navigation.showApprovals() }
        if let store = model.featureStore {
            StoreApprovalsRow(store: store, isSelected: isSelected, select: select)
        } else {
            ApprovalsRow(count: model.pendingApprovalCount, isSelected: isSelected, select: select)
        }
    }
}

/// "Needs you" with the pending count in `accent`; the whole row hides at zero.
struct ApprovalsRow: View {
    let count: Int
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        if count > 0 || isSelected {
            Button(action: select) {
                HStack {
                    Text("Needs you").aryaText(AryaFont.body, AryaColor.ink)
                    Spacer()
                    CountLabel(count, style: AryaFont.monoStrong, color: AryaColor.accent)
                }
                .padding(.horizontal, AryaSpace.s2)
                .frame(height: AryaSize.rowHeight)
                .background(
                    isSelected ? AryaColor.selection : .clear,
                    in: RoundedRectangle(cornerRadius: AryaRadius.small)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, AryaSpace.s4)
            .accessibilityLabel("Needs you, \(count) pending")
        }
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
