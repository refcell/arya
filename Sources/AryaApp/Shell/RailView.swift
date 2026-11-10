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
            if !model.stewards.isEmpty {
                Button {
                    model.navigation.showPortfolio()
                } label: {
                    RailRow(
                        "All stewards", trailing: "\(model.stewards.count)",
                        isSelected: model.navigation.destination == .portfolio,
                        trailingIsMono: true)
                }
                .buttonStyle(.plain)
                .help("Every steward in one table (Command-9)")
            }
            needsYouRow
            if !model.stewards.isEmpty {
                RailGroupLabel("Stewards")
                    .padding(.bottom, AryaSpace.s1)
            }
            ForEach(sortedStewards) { steward in
                stewardRows(steward)
            }
        }
        .padding(.horizontal, AryaSpace.s2)
        .padding(.top, AryaSize.trafficLightInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The steward's metric series from the ledger, when the feature store has loaded it.
    private func metric(_ steward: String) -> MetricSeries? {
        guard case .loaded(let events) = model.featureStore?.state else { return nil }
        return MetricSeries.build(events: events, steward: steward)
    }

    /// The runs going now (workspace `liveRuns`, else projected from the ledger).
    private var liveLines: [LiveLine] {
        guard case .loaded(let events) = model.featureStore?.state else { return model.liveLines }
        return StatusBarLine.lines(
            live: model.liveLines, stewards: model.stewards, runs: model.runs, events: events)
    }

    private func sidebarRow(_ steward: StewardSummary) -> StatusMapping.SidebarRow {
        let series = metric(steward.id)
        return StatusMapping.SidebarRow(
            steward, pending: model.pendingApprovals(steward: steward.id),
            latest: series?.latest?.value, target: series?.definition.target,
            onTrack: series?.meetsTarget, isSelected: model.navigation.steward == steward.id,
            runningSteps: liveLines.last { $0.steward == steward.id }?.steps)
    }

    private var sortedStewards: [StewardSummary] {
        StatusMapping.sorted(model.stewards.map { ($0, sidebarRow($0)) })
    }

    @ViewBuilder private func stewardRows(_ steward: StewardSummary) -> some View {
        let runs = model.runs[steward.id] ?? []
        let isSelected = model.navigation.steward == steward.id
        Button {
            model.navigation.select(steward: steward.id)
        } label: {
            let row = sidebarRow(steward)
            RailRow(
                steward.name, status: row.status, trailing: row.trailing,
                isSelected: isSelected && model.navigation.run == nil
                    && model.navigation.destination != .approvals,
                trailingIsMono: row.trailingIsMono, trailingIsAlert: row.trailingIsAlert,
                accessibility: row.accessibility)
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
                // A run that started in the last half minute lights up as it arrives.
                .aryaArrival(now.timeIntervalSince(run.startedAt) < 30)
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
