import Arya
import AryaDesign
import SwiftUI

/// One row of the portfolio: every fact a person needs to compare stewards at a glance.
struct PortfolioRow: Identifiable, Equatable {
    var id: String
    var name: String
    var outcome: String
    /// "0.84 / 0.90 confirmed_within_1d", or "no metric".
    var metric: String
    var trend: [Double]
    var behind: Bool
    var state: String
    var waiting: Int
    /// "3h", or "never".
    var lastRun: String
    /// "next 14:00", "paused", "on demand".
    var nextWake: String
    var health: StatusMapping.SidebarRow.Health

    static func build(
        stewards: [StewardSummary], runs: [String: [RunSummary]], approvals: [ApprovalSummary],
        events: [FeatureEvent], now: Date, timeZone: TimeZone = .current
    ) -> [PortfolioRow] {
        let rows = stewards.map { steward -> PortfolioRow in
            let state = OutcomeState.build(events: events, steward: steward.id, now: now)
            let series = MetricSeries.build(events: events, steward: steward.id)
            let waiting = approvals.filter { $0.steward == steward.id }.count
            let latest = series?.latest?.value
            var metric = "no metric"
            if let definition = series?.definition {
                let value = latest.map(StatusMapping.metric) ?? "—"
                let target = definition.target.map { " / \(StatusMapping.metric($0))" } ?? ""
                metric = "\(value)\(target) \(definition.name)"
            }
            let sidebar = StatusMapping.SidebarRow(
                steward, pending: waiting, latest: latest, target: series?.definition.target,
                onTrack: series?.meetsTarget, isSelected: false)
            let wake: String
            if steward.status == .paused {
                wake = "paused"
            } else if case .at(let date) = state.wake {
                wake = "next \(AryaTime.upcoming(date, now: now, timeZone: timeZone))"
            } else {
                wake = "on demand"
            }
            let last = runs[steward.id]?.map(\.startedAt).max()
            return PortfolioRow(
                id: steward.id, name: steward.name, outcome: steward.outcome, metric: metric,
                trend: state.trend, behind: series?.meetsTarget == false, state: stateWord(steward),
                waiting: waiting,
                lastRun: last.map { AryaTime.label($0, now: now, timeZone: timeZone) } ?? "never",
                nextWake: wake, health: sidebar.health)
        }
        return rows.sorted {
            $0.health != $1.health
                ? $0.health < $1.health
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func stateWord(_ steward: StewardSummary) -> String {
        switch steward.status {
        case .active: steward.ready ? "live" : "rehearsing"
        case .paused: "paused"
        case .retired: "retired"
        }
    }
}

/// The portfolio: one dense table of every steward (outcome, metric against target with a
/// sparkline, state, approvals waiting, last run, next wake), sorted by need. A row opens the
/// steward.
struct PortfolioView: View {
    let model: AppModel
    let now: Date

    private static let columns: [(String, CGFloat?)] = [
        ("Steward", 168), ("Metric", nil), ("Trend", AryaSize.sparklineWidth),
        ("State", 56), ("Needs you", 64), ("Last run", 56), ("Next", 88),
    ]

    var body: some View {
        let rows = PortfolioRow.build(
            stewards: model.stewards, runs: model.runs, approvals: model.approvals,
            events: events, now: now)
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            PageTitle(
                title: "Stewards",
                subtitle: rows.count == 1 ? "1 steward" : "\(rows.count) stewards, sorted by need."
            )
            .padding(.horizontal, AryaSize.pagePadding)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(rows) { row in
                        Button {
                            model.navigation.select(steward: row.id)
                        } label: {
                            line(row)
                        }
                        .buttonStyle(.plain)
                        AryaHairline()
                    }
                }
                .padding(.horizontal, AryaSize.pagePadding)
            }
        }
        .padding(.top, AryaSize.titleBarInset)
    }

    private var events: [FeatureEvent] {
        guard case .loaded(let events) = model.featureStore?.state else { return [] }
        return events
    }

    private var header: some View {
        HStack(spacing: AryaSpace.s2) {
            ForEach(Self.columns, id: \.0) { title, width in
                cell(width) { Text(title).aryaText(AryaFont.label, AryaColor.inkFaint) }
            }
        }
        .frame(height: AryaSize.rowHeight)
        .aryaHairline(edge: .bottom)
    }

    private func line(_ row: PortfolioRow) -> some View {
        HStack(spacing: AryaSpace.s2) {
            cell(168) {
                HStack(spacing: AryaSpace.s2) {
                    StatusDot(row.waiting > 0 ? .needsYou : row.state == "paused" ? .paused : .idle)
                    Text(row.name).aryaText(AryaFont.body, AryaColor.ink).lineLimit(1)
                        .help(row.outcome)
                }
            }
            cell(nil) {
                Text(row.metric)
                    .aryaText(AryaFont.monoSmall, row.behind ? AryaColor.negative : AryaColor.ink)
                    .lineLimit(1)
            }
            cell(AryaSize.sparklineWidth) {
                if row.trend.count > 1 {
                    Sparkline(row.trend, onTarget: !row.behind)
                        .frame(width: AryaSize.sparklineWidth, height: AryaSize.sparklineHeight / 2)
                }
            }
            cell(56) { Text(row.state).aryaText(AryaFont.caption, AryaColor.inkMuted) }
            cell(64) {
                Text(row.waiting > 0 ? "\(row.waiting)" : "—")
                    .aryaText(
                        AryaFont.monoSmall, row.waiting > 0 ? AryaColor.ink : AryaColor.inkFaint)
            }
            cell(56) { Text(row.lastRun).aryaText(AryaFont.monoSmall, AryaColor.inkMuted) }
            cell(88) { Text(row.nextWake).aryaText(AryaFont.monoSmall, AryaColor.inkMuted) }
        }
        .frame(height: AryaSize.rowHeight + AryaSpace.s1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(row.name)")
    }

    @ViewBuilder
    private func cell<Content: View>(_ width: CGFloat?, @ViewBuilder _ content: () -> Content)
        -> some View
    {
        if let width {
            content().frame(width: width, alignment: .leading)
        } else {
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
