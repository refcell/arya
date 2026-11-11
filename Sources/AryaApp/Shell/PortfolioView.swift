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
    /// The department it serves, or "" when none is set.
    var department: String = ""
    /// The portfolio group it sits in: the department, or `Unassigned`.
    var group: String { department.isEmpty ? RailGroup.unassigned : department }

    static func build(
        stewards: [StewardSummary], runs: [String: [RunSummary]], approvals: [ApprovalSummary],
        events: [FeatureEvent], now: Date, serve: FeatureServe? = nil,
        departments: [String: String] = [:], live: [LiveLine] = [], fleet: [String: String] = [:],
        histories: [String: RunHistory] = [:],
        timeZone: TimeZone = .current
    ) -> [PortfolioRow] {
        let going = StatusBarLine.running(live)
        let rows = stewards.map { steward -> PortfolioRow in
            let state = OutcomeState.build(
                events: events, steward: steward.id, now: now, serve: serve)
            let series = MetricSeries.build(events: events, steward: steward.id)
            let waiting = approvals.filter { $0.steward == steward.id }.count
            let latest = series?.latest?.value
            var metric = "no metric"
            if let definition = series?.definition {
                let figure = MetricText.figure(
                    latest, target: definition.target, offTarget: series?.meetsTarget == false)
                metric = "\(figure) \(definition.name)"
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
            // Workspace `runHistory` per steward: rehearsal bursts never flatten the bars.
            let history: RunHistory? = histories[steward.id]
            let totals: [Int] = history?.days.map(\.runs) ?? []
            let failed: [Int] = history?.days.map(\.failed) ?? []
            let cost: String = StewardPulse.costToday(mine, now: now, timeZone: timeZone)
            // Typed lets, so the initializer below never strains the type checker under load.
            let behind: Bool = StatusMapping.isBehind(
                steward, fleet: fleet, meetsTarget: series?.meetsTarget)
            let lastRun: String = last.map { ThreadRow.shortTime($0, now: now) } ?? "never"
            let costToday: String = cost.replacingOccurrences(of: " today", with: "")
            let running: Bool = going.contains(steward.id)
            let department: String = departments[steward.id] ?? ""
            let word: String = stateWord(steward)
            return PortfolioRow(
                id: steward.id, name: steward.name, outcome: steward.outcome, metric: metric,
                trend: state.trend, behind: behind, state: word, waiting: waiting,
                lastRun: lastRun, nextWake: wake, health: sidebar.health, runsPerDay: totals,
                failedPerDay: failed, costToday: costToday, running: running,
                department: department)
        }
        // Need first: health, then the most waiting on a person, then by name.
        return rows.sorted {
            if $0.health != $1.health { return $0.health < $1.health }
            if $0.waiting != $1.waiting { return $0.waiting > $1.waiting }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// "3 need you · 2 behind · 1 running", skipping zeros; nil when all are zero.
    static func counts(_ rows: [PortfolioRow]) -> String? {
        let parts = [
            (rows.filter { $0.waiting > 0 }.count, "need you"),
            (rows.filter(\.behind).count, "behind"),
            (rows.filter(\.running).count, "running"),
        ]
        .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            events: events, now: now, serve: model.featureStore?.serve,
            departments: model.departments, live: model.liveLines, fleet: model.fleetStatus,
            histories: model.runHistory)
        let grouped = rows.contains { !$0.department.isEmpty }
        let total = rows.count == 1 ? "1 steward" : "\(rows.count) stewards"
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            PageTitle(
                title: "Stewards",
                subtitle: ([total + ", sorted by need"]
                    + [PortfolioRow.counts(rows)].compactMap { $0 })
                    .joined(separator: " · ")
            )
            .padding(.horizontal, AryaSize.pagePadding)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if grouped {
                        ForEach(PortfolioDepartments.lines(rows)) { group in
                            groupHeader(group)
                            if !model.collapsedPortfolioGroups.contains(group.id) {
                                ForEach(rows.filter { $0.group == group.id }) { row in
                                    rowButton(row)
                                }
                            }
                        }
                    } else {
                        ForEach(rows) { row in rowButton(row) }
                    }
                    FleetActivity(
                        lines: FleetActivity.collapsed(
                            FleetActivity.lines(
                                events: events, stewards: model.stewards, now: now))
                    ) { model.navigation.select(steward: $0) }
                    .padding(.top, AryaSpace.s6)
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

    @ViewBuilder private func rowButton(_ row: PortfolioRow) -> some View {
        Button {
            model.navigation.select(steward: row.id)
        } label: {
            line(row)
        }
        .buttonStyle(.plain)
        AryaHairline()
    }

    /// A department's fold row: the sidebar's header (count, waiting, behind, live) plus its
    /// runs over 7 days in the Runs column's place.
    private func groupHeader(_ group: PortfolioDepartments.Line) -> some View {
        let collapsed = model.collapsedPortfolioGroups.contains(group.id)
        return Button {
            withAnimation(AryaMotion.frozenByProcess ? nil : AryaMotion.quick) {
                if collapsed {
                    model.collapsedPortfolioGroups.remove(group.id)
                } else {
                    model.collapsedPortfolioGroups.insert(group.id)
                }
            }
        } label: {
            RailDepartmentHeader(
                group.id, count: group.stewards, collapsed: collapsed, waiting: group.waiting,
                behind: group.behind, running: group.running > 0)
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(group.id)" : "Hide \(group.id)")
        .aryaHairline(edge: .bottom)
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

/// The portfolio's department groups: stewards, behind, waiting, running, and runs over 7 days.
enum PortfolioDepartments {
    struct Line: Equatable, Identifiable {
        var id: String
        var stewards: Int
        var behind: Int
        var waiting: Int
        var running: Int
        var runsPerDay: [Int]
        var failedPerDay: [Int]
    }

    /// One line per department, most waiting first, then most behind, then by name.
    static func lines(_ rows: [PortfolioRow]) -> [Line] {
        let grouped = Dictionary(grouping: rows) {
            $0.department.isEmpty ? RailGroup.unassigned : $0.department
        }
        func sum(_ arrays: [[Int]]) -> [Int] {
            let width = arrays.map(\.count).max() ?? 0
            return (0..<width).map { day in
                arrays.reduce(0) { $0 + (day < $1.count ? $1[day] : 0) }
            }
        }
        return grouped.map { name, members in
            Line(
                id: name, stewards: members.count, behind: members.filter(\.behind).count,
                waiting: members.map(\.waiting).reduce(0, +),
                running: members.filter(\.running).count,
                runsPerDay: sum(members.map(\.runsPerDay)),
                failedPerDay: sum(members.map(\.failedPerDay)))
        }
        .sorted {
            if $0.waiting != $1.waiting { return $0.waiting > $1.waiting }
            if $0.behind != $1.behind { return $0.behind > $1.behind }
            return $0.id < $1.id
        }
    }
}

/// The fleet's recent activity under the portfolio table: who did what, newest first, skipping
/// step-level and adapter noise. A line opens its steward.
struct FleetActivity: View {
    struct Line: Equatable, Identifiable {
        var id: String
        var time: String
        var steward: String
        var name: String
        var text: String
        var failed: Bool
        /// When it happened; lines are strictly newest first.
        var at: Date = .distantPast
        /// Like lines in a row folded into this one ("labeled MSG-140 ×5").
        var count = 1

        /// The text with its repeat count.
        var said: String { count > 1 ? "\(text) ×\(count)" : text }
    }

    let lines: [Line]
    let open: (String) -> Void

    static let timeWidth: CGFloat = 40

    /// What each event type reads as; types not listed are skipped.
    static let words: [String: String] = [
        "run.started": "started a run", "run.finished": "finished a run",
        "action.executed": "took an action", "approval.requested": "asked for sign-off",
        "approval.decided": "got a decision", "plan.updated": "updated its plan",
        "report.sent": "sent a report", "inbox.message": "got a message",
        "steward.paused": "was paused", "steward.resumed": "was resumed",
        "steward.ready": "went live", "routine.proposed": "proposed a routine",
        "proposal.gated": "had a change gated", "rehearsal.finished": "finished a rehearsal",
        "run.delegated": "handed work to a crew", "memory.added": "learned something",
    ]

    static func lines(
        events: [FeatureEvent], stewards: [StewardSummary], now: Date, limit: Int = 24
    ) -> [Line] {
        let names = Dictionary(
            stewards.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Proposed actions by run and action id, so an execution says what it did.
        var proposed: [String: (kind: String, target: String)] = [:]
        for event in events where event.type == "action.proposed" {
            guard let run = event.run, let action = event.payload["action"],
                let id = action["id"]?.string, let kind = action["kind"]?.string
            else { continue }
            proposed["\(run)/\(id)"] = (kind, action["target"]?.string ?? "")
        }
        var candidates: [Line] = []
        for event in events.reversed() {
            guard candidates.count < limit * 20 else { break }
            guard let steward = event.steward, let name = names[steward],
                var text = words[event.type]
            else { continue }
            let failed =
                event.type == "run.finished"
                && ["failed", "error"].contains(event.payload["status"]?.string ?? "")
            if failed { text = "had a run fail" }
            // Name the action: "labeled MSG-140", "asked to send an email to LEAD-1002".
            if event.type == "action.executed", let run = event.run,
                let id = event.payload["action"]?.string, let action = proposed["\(run)/\(id)"]
            {
                text =
                    HumanText.pastVerb(action.kind)
                    + (action.target.isEmpty ? "" : " " + HumanText.name(action.target))
            } else if event.type == "approval.requested", let action = event.payload["action"],
                let kind = action["kind"]?.string
            {
                let sentence = ActionWords.sentence(
                    kind: kind, target: action["target"]?.string ?? "")
                text = "asked to " + sentence.prefix(1).lowercased() + sentence.dropFirst()
            }
            candidates.append(
                Line(
                    id: event.id, time: ThreadRow.shortTime(event.at, now: now),
                    steward: steward, name: name, text: text, failed: failed, at: event.at))
        }
        // Strictly newest first; stewards interleave only among lines of the same minute.
        let ordered = candidates.enumerated().sorted {
            $0.element.at != $1.element.at ? $0.element.at > $1.element.at : $0.offset < $1.offset
        }.map(\.element)
        var out: [Line] = []
        var bucket: [Line] = []
        func flush() {
            out += interleave(bucket, limit: bucket.count, keepRest: true)
            bucket = []
        }
        for line in ordered {
            if let first = bucket.first, minute(first.at) != minute(line.at) { flush() }
            bucket.append(line)
        }
        flush()
        return Array(out.prefix(limit))
    }

    /// Like lines in a row (same steward, same words) folded into one with a count.
    static func collapsed(_ lines: [Line]) -> [Line] {
        var out: [Line] = []
        for line in lines {
            if let last = out.last, last.steward == line.steward, last.text == line.text {
                out[out.count - 1].count += 1
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// The first half of `lines` fills the left column top to bottom, the rest the right, so
    /// reading down the left and then down the right keeps the list's order.
    static func columns(_ lines: [Line]) -> (left: [Line], right: [Line]) {
        let half = (lines.count + 1) / 2
        return (Array(lines.prefix(half)), Array(lines.dropFirst(half)))
    }

    private static func minute(_ date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down))
    }

    /// Newest first, but at most `run` lines in a row from one steward: a busy steward's
    /// extra lines wait until another steward's line has been shown. Stops when only the busy
    /// steward is left.
    /// `keepRest` appends what is left once only the busy steward remains, instead of
    /// dropping it.
    static func interleave(_ lines: [Line], limit: Int, run: Int = 2, keepRest: Bool = false)
        -> [Line]
    {
        var pending = lines
        var out: [Line] = []
        while out.count < limit, !pending.isEmpty {
            let tail = out.suffix(run).map(\.steward)
            let blocked = tail.count == run && Set(tail).count == 1 ? tail.first : nil
            guard let index = pending.firstIndex(where: { $0.steward != blocked }) else {
                if keepRest { out += pending.prefix(limit - out.count) }
                break
            }
            out.append(pending.remove(at: index))
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fleet activity").aryaText(AryaFont.label, AryaColor.inkFaint)
                .frame(height: AryaSize.rowHeight)
            AryaHairline()
            if lines.isEmpty {
                Text("Nothing yet.").aryaText(AryaFont.caption, AryaColor.inkFaint)
                    .frame(height: AryaSize.rowHeight)
            }
            // One list newest first, split into two columns read down then across.
            let columns = Self.columns(lines)
            HStack(alignment: .top, spacing: AryaSpace.s6) {
                column(columns.left)
                column(columns.right)
            }
        }
    }

    private func column(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Button {
                    open(line.steward)
                } label: {
                    HStack(spacing: AryaSpace.s2) {
                        Text(line.time).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                            .frame(width: Self.timeWidth, alignment: .leading)
                        Text(line.name).aryaText(AryaFont.body, AryaColor.ink).lineLimit(1)
                        Text(line.said)
                            .aryaText(
                                AryaFont.caption,
                                line.failed ? AryaColor.negative : AryaColor.inkMuted
                            )
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: AryaSize.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// What each department's outcomes did over the last week, for the sidebar on All stewards:
/// recoveries, misses, and moves, never a copy of the queue.
enum DepartmentOutcomes {
    struct Line: Identifiable, Hashable {
        var id: String
        var name: String
        /// "back on target, 0.84 → 0.96", "fell below target, 0.80 → 0.75", "0.90 → 0.96".
        var text: String
        /// True when the move is the good way (or recovered); false when it missed or slid.
        var good: Bool?
    }

    struct Group: Identifiable, Hashable {
        var id: String { department }
        var department: String
        var lines: [Line]
    }

    /// At most `limit` lines that moved (steady ones left out), in group order, so the list
    /// fits under the threads without running off the window.
    static func capped(_ groups: [Group], limit: Int) -> [Group] {
        var left = limit
        return groups.compactMap { group in
            let lines = Array(group.lines.filter { $0.good != nil }.prefix(max(0, left)))
            left -= lines.count
            return lines.isEmpty ? nil : Group(department: group.department, lines: lines)
        }
    }

    /// Readings back the comparison starts from: a week of daily points.
    static let window = 7

    /// One line per steward with at least two readings; departments by name, Unassigned last,
    /// and inside each the misses first, then recoveries, then moves.
    static func build(series: [(StewardSummary, MetricSeries)], departments: [String: String])
        -> [Group]
    {
        var groups: [String: [(Line, Int)]] = [:]
        for (steward, metric) in series where metric.points.count >= 2 {
            let latest = metric.points[metric.points.count - 1].value
            let start = metric.points[max(0, metric.points.count - 1 - window)].value
            let move = "\(MetricText.value(start)) → \(MetricText.value(latest))"
            let up = metric.definition.direction == .up
            func meets(_ value: Double) -> Bool? {
                metric.definition.target.map { up ? value >= $0 : value <= $0 }
            }
            let line: (Line, Int)
            switch (meets(start), meets(latest)) {
            case (false?, true?):
                line = (
                    Line(
                        id: steward.id, name: steward.name, text: "back on target, " + move,
                        good: true), 1
                )
            case (true?, false?):
                line = (
                    Line(
                        id: steward.id, name: steward.name,
                        text: "fell below target, " + move, good: false), 0
                )
            case (_, false?):
                line = (
                    Line(
                        id: steward.id, name: steward.name, text: "still behind, " + move,
                        good: false), 0
                )
            default:
                let delta = latest - start
                let good: Bool? = abs(delta) < 0.005 ? nil : (delta > 0) == up
                line = (
                    Line(
                        id: steward.id, name: steward.name,
                        text: abs(delta) < 0.005 ? "steady at \(MetricText.value(latest))" : move,
                        good: good), 2
                )
            }
            groups[departments[steward.id] ?? "Unassigned", default: []].append(line)
        }
        return groups.keys.sorted {
            ($0 == "Unassigned" ? 1 : 0, $0) < ($1 == "Unassigned" ? 1 : 0, $1)
        }.map { department in
            Group(
                department: department,
                lines: (groups[department] ?? []).sorted { $0.1 < $1.1 }.map(\.0))
        }
    }
}
