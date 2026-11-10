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
        let shown = RailGroup.visible(groups, collapsed: model.collapsedDepartments)
        let items = RailOrder.items(
            stewards: shown, runs: model.runs, selected: model.navigation.steward)
        let current = RailOrder.current(model.navigation)
        if let next = RailOrder.step(from: current, by: offset, in: items) {
            // The selection glides with j/k; frozen in snapshots and under Reduce Motion.
            withAnimation(AryaMotion.frozenByProcess ? nil : AryaMotion.quick) {
                model.navigation.select(next)
            }
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
            if !model.stewards.isEmpty, model.departments.isEmpty {
                RailGroupLabel("Stewards")
                    .padding(.bottom, AryaSpace.s1)
            }
            ForEach(groups) { group in
                if let department = group.department {
                    departmentHeader(department, group.stewards)
                }
                if !(group.department.map(model.collapsedDepartments.contains) ?? false) {
                    ForEach(group.stewards) { steward in
                        stewardRows(steward)
                    }
                }
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
        StatusBarLine.lines(live: model.liveLines)
    }

    private func sidebarRow(_ steward: StewardSummary) -> StatusMapping.SidebarRow {
        let series = metric(steward.id)
        return StatusMapping.SidebarRow(
            steward, pending: model.pendingApprovals(steward: steward.id),
            latest: series?.latest?.value, target: series?.definition.target,
            onTrack: series?.meetsTarget, isSelected: model.navigation.steward == steward.id,
            runningSteps: liveLines.last { $0.steward == steward.id }?.steps,
            fleet: model.fleetStatus)
    }

    private var sortedStewards: [StewardSummary] {
        StatusMapping.sorted(model.stewards.map { ($0, sidebarRow($0)) })
    }

    private var groups: [RailGroup] {
        RailGroup.build(sorted: sortedStewards, departments: model.departments)
    }

    /// A department's fold row: chevron, name, count, and what needs a look inside it (waiting
    /// approvals, stewards behind target, a live dot while one runs).
    private func departmentHeader(_ name: String, _ stewards: [StewardSummary]) -> some View {
        let collapsed = model.collapsedDepartments.contains(name)
        let rows = stewards.map(sidebarRow)
        let waiting = stewards.map { model.pendingApprovals(steward: $0.id) }.reduce(0, +)
        let behind = rows.filter { $0.health == .behind }.count
        let running = stewards.contains { id in liveLines.contains { $0.steward == id.id } }
        return Button {
            withAnimation(AryaMotion.frozenByProcess ? nil : AryaMotion.quick) {
                if collapsed {
                    model.collapsedDepartments.remove(name)
                } else {
                    model.collapsedDepartments.insert(name)
                }
            }
        } label: {
            RailDepartmentHeader(
                name, count: stewards.count, collapsed: collapsed, waiting: waiting,
                behind: behind, running: running)
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(name)" : "Hide \(name)")
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
                        model.title(of: run),
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

/// A sidebar department group's header: a fold chevron, the name as a label, the steward
/// count, then "2 waiting" in ink and "1 behind" in red when any, and a live dot while running.
struct RailDepartmentHeader: View {
    let name: String
    let count: Int
    let collapsed: Bool
    let waiting: Int
    let behind: Int
    let running: Bool

    init(
        _ name: String, count: Int, collapsed: Bool, waiting: Int, behind: Int, running: Bool
    ) {
        self.name = name
        self.count = count
        self.collapsed = collapsed
        self.waiting = waiting
        self.behind = behind
        self.running = running
    }

    var body: some View {
        HStack(spacing: AryaSpace.s1) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(AryaColor.inkFaint)
                .frame(width: AryaSpace.s3)
            Text(name.uppercased()).aryaText(AryaFont.label, AryaColor.inkMuted).lineLimit(1)
            Text("\(count)").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            Spacer(minLength: AryaSpace.s1)
            if running { AryaLiveDot() }
            if waiting > 0 {
                Text("\(waiting) waiting").aryaText(AryaFont.monoSmall, AryaColor.ink)
            }
            if behind > 0 {
                Text("\(behind) behind").aryaText(AryaFont.monoSmall, AryaColor.negative)
            }
        }
        .padding(.horizontal, AryaSpace.s1)
        .frame(height: AryaSize.rowHeight - AryaSpace.s1)
        .padding(.top, AryaSpace.s2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
