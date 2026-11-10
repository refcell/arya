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

    /// The metric without its name: "0.84 / 0.90", or "no metric".
    var metricFigure: String {
        guard metric != "no metric", let space = metric.lastIndex(of: " ") else { return metric }
        return String(metric[..<space])
    }
    /// Top-level runs per day for the last week, oldest first, and the failed ones.
    var runsPerDay: [Int] = []
    var failedPerDay: [Int] = []
    /// "$0.0042", or "—" when no run today reported a cost.
    var costToday: String = "—"
    /// A run is going right now.
    var running: Bool = false

    static func build(
        stewards: [StewardSummary], runs: [String: [RunSummary]], approvals: [ApprovalSummary],
        events: [FeatureEvent], now: Date, serve: FeatureServe? = nil,
        timeZone: TimeZone = .current
    ) -> [PortfolioRow] {
        let rows = stewards.map { steward -> PortfolioRow in
            let state = OutcomeState.build(
                events: events, steward: steward.id, now: now, serve: serve)
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
                let time = AryaTime.upcoming(date, now: now, timeZone: timeZone)
                wake = state.serving == false ? "due \(time)" : "next \(time)"
            } else {
                wake = "on demand"
            }
            let mine = runs[steward.id] ?? []
            let last = mine.map(\.startedAt).max()
            let (totals, failed) = StewardPulse.perDay(
                mine.filter { $0.parent == nil }, now: now, timeZone: timeZone)
            let cost = StewardPulse.costToday(mine, now: now, timeZone: timeZone)
            return PortfolioRow(
                id: steward.id, name: steward.name, outcome: steward.outcome, metric: metric,
                trend: state.trend, behind: series?.meetsTarget == false, state: stateWord(steward),
                waiting: waiting,
                lastRun: last.map { AryaTime.label($0, now: now, timeZone: timeZone) } ?? "never",
                nextWake: wake, health: sidebar.health, runsPerDay: totals, failedPerDay: failed,
                costToday: cost.replacingOccurrences(of: " today", with: ""),
                running: mine.contains { $0.status == .running })
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
        ("Steward", nil), ("Metric", 88), ("Trend", AryaSize.sparklineWidth),
        ("State", 56), ("Runs 7d", 64), ("Needs you", 64), ("Cost today", 72),
        ("Last run", 56), ("Next", 88),
    ]

    var body: some View {
        let rows = PortfolioRow.build(
            stewards: model.stewards, runs: model.runs, approvals: model.approvals,
            events: events, now: now, serve: model.featureStore?.serve)
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
            cell(nil) {
                HStack(spacing: AryaSpace.s2) {
                    StatusDot(row.waiting > 0 ? .needsYou : row.state == "paused" ? .paused : .idle)
                    Text(row.name).aryaText(AryaFont.body, AryaColor.ink).lineLimit(1)
                        .help(row.outcome)
                }
            }
            cell(88) {
                // "0.84 / 0.90"; the metric's name is in the help.
                Text(row.metricFigure)
                    .aryaText(AryaFont.monoSmall, row.behind ? AryaColor.negative : AryaColor.ink)
                    .lineLimit(1)
                    .help(row.metric)
            }
            cell(AryaSize.sparklineWidth) {
                if row.trend.count > 1 {
                    Sparkline(row.trend, onTarget: !row.behind)
                        .frame(width: AryaSize.sparklineWidth, height: AryaSize.sparklineHeight / 2)
                }
            }
            cell(56) {
                HStack(spacing: AryaSpace.s1) {
                    if row.running { AryaLiveDot() }
                    Text(row.running ? "running" : row.state)
                        .aryaText(
                            AryaFont.caption, row.running ? AryaColor.positive : AryaColor.inkMuted)
                }
            }
            cell(64) {
                DayBars(row.runsPerDay, failed: row.failedPerDay, height: 12)
                    .help("\(row.runsPerDay.reduce(0, +)) runs in 7 days")
            }
            cell(64) {
                Text(row.waiting > 0 ? "\(row.waiting)" : "—")
                    .aryaText(
                        AryaFont.monoSmall, row.waiting > 0 ? AryaColor.ink : AryaColor.inkFaint)
            }
            cell(72) { Text(row.costToday).aryaText(AryaFont.monoSmall, AryaColor.inkMuted) }
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
