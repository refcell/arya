import AryaDesign
import SwiftUI

// The Overview's working panels, projected from the ledger: METRICS (the outcome over 30 days
// against its target, plus the steward's operating series), NOW (runs in progress or the next
// wake), FINDINGS (what needs attention or changed), and IMPACT (which actions moved the
// metric). Runtime's findings and impact reads replace the last two when they land.

/// Seconds in a day, for day buckets counted back from now.
private let day: TimeInterval = 86_400

/// Runs, actions, and holds for one steward, rehearsals left out.
struct OutcomeLedger {
    var runs: [FeatureEvent] = []
    var finished: [String: FeatureEvent] = [:]
    var executed: [FeatureEvent] = []
    var holds: [FeatureEvent] = []
    /// Action id → kind, within a run (`run/action`).
    var kinds: [String: String] = [:]
    var metrics: [FeatureEvent] = []
    var status: [String: String] = [:]

    init(events: [FeatureEvent], steward: String) {
        let rehearsals = OutcomeRuns.rehearsalRuns(events)
        for event in events where event.steward == steward {
            if let run = event.run, rehearsals.contains(run) { continue }
            switch event.type {
            case "run.started": runs.append(event)
            case "run.finished": if let run = event.run { finished[run] = event }
            case "action.proposed":
                if let id = event.payload["action"]?["id"]?.string,
                    let kind = event.payload["action"]?["kind"]?.string
                {
                    kinds["\(event.run ?? "")/\(id)"] = kind
                }
            case "action.executed": executed.append(event)
            case "approval.requested": holds.append(event)
            case "metric.recorded": metrics.append(event)
            case "run.adapter.event":
                if let run = event.run,
                    let detail = event.payload["message"]?["params"]?["event"]?["detail"]?.string
                {
                    status[run] = detail
                }
            default: continue
            }
        }
    }

    func kind(_ executed: FeatureEvent) -> String? {
        guard let id = executed.payload["action"]?.string else { return nil }
        return kinds["\(executed.run ?? "")/\(id)"]
    }

    /// Counts in `buckets` equal slices from the first event (at most `days` back) to now,
    /// oldest first, so a burst of recent work still draws a shape.
    static func daily(_ events: [FeatureEvent], now: Date, days: Int, buckets: Int = 14)
        -> [Double]
    {
        let earliest = events.map(\.at).min() ?? now
        let span = max(3600, min(Double(days) * day, now.timeIntervalSince(earliest) + 1))
        var counts = Array(repeating: 0.0, count: buckets)
        for event in events {
            let back = now.timeIntervalSince(event.at)
            guard back >= 0, back < span else { continue }
            let index = buckets - 1 - Int(back / span * Double(buckets))
            counts[max(0, index)] += 1
        }
        return counts
    }
}

/// One operating series beside the outcome chart.
struct OutcomeSeries: Hashable, Sendable, Identifiable {
    var name: String
    /// Mono value, "41 / 7d" or "0.62".
    var value: String
    var values: [Double]
    var tone: Tone = .plain

    enum Tone: Hashable, Sendable { case plain, attention, negative }

    var id: String { name }
}

/// The METRICS panel's data.
struct OutcomeMetrics: Hashable, Sendable {
    var metric: MetricDefinition?
    /// The outcome, one value per day over the window, oldest first.
    var points: [MetricPoint]
    var series: [OutcomeSeries]

    static let windowDays = 30
    static let seriesDays = 14

    static func build(events: [FeatureEvent], steward: String, state: OutcomeState, now: Date)
        -> OutcomeMetrics
    {
        let ledger = OutcomeLedger(events: events, steward: steward)
        let from = now.addingTimeInterval(-Double(windowDays) * day)
        let points = state.points.filter { $0.day >= from }
        func count(_ name: String, _ events: [FeatureEvent], tone: OutcomeSeries.Tone = .plain)
            -> OutcomeSeries
        {
            let values = OutcomeLedger.daily(events, now: now, days: seriesDays)
            let week = events.filter { $0.at >= now.addingTimeInterval(-7 * day) }.count
            return OutcomeSeries(
                name: name, value: "\(week) / 7d", values: values, tone: week > 0 ? tone : .plain)
        }
        let finished = ledger.runs.compactMap { ledger.finished[$0.run ?? ""] }
        let failed = finished.filter {
            let status = $0.payload["status"]?.string ?? "completed"
            return status != "completed" && status != "succeeded"
        }
        var series = [
            count("runs", finished), count("actions taken", ledger.executed),
            count("held for you", ledger.holds, tone: .attention),
            count("failed runs", failed, tone: .negative),
        ]
        let others = Dictionary(grouping: ledger.metrics) { $0.payload["metric"]?.string ?? "" }
        for (name, readings) in others.sorted(by: { $0.key < $1.key })
        where !name.isEmpty && name != state.metric?.name {
            let values = readings.compactMap { $0.payload["value"]?.number }
            guard let last = values.last else { continue }
            series.append(
                OutcomeSeries(
                    name: name, value: MetricText.value(last), values: Array(values.suffix(30))))
        }
        return OutcomeMetrics(metric: state.metric, points: points, series: series)
    }
}

/// NOW: runs in progress with an estimated progress, else when the next one starts.
struct OutcomeNow: Hashable, Sendable {
    struct Live: Hashable, Sendable, Identifiable {
        var run: String
        var title: String
        var doing: String?
        var elapsed: TimeInterval
        /// 0…1, elapsed against the typical run; nil without finished runs to compare.
        var progress: Double?
        var id: String { run }
    }

    var live: [Live]
    var next: String
    var last: String?

    static func build(
        events: [FeatureEvent], steward: String, wake: OutcomeWake, now: Date
    ) -> OutcomeNow {
        let ledger = OutcomeLedger(events: events, steward: steward)
        let durations = ledger.runs.compactMap { started -> TimeInterval? in
            guard let end = ledger.finished[started.run ?? ""] else { return nil }
            return end.at.timeIntervalSince(started.at)
        }
        .sorted()
        let typical = durations.isEmpty ? nil : durations[durations.count / 2]
        let live = ledger.runs.filter { ledger.finished[$0.run ?? ""] == nil }.map { started in
            let run = started.run ?? started.id
            let elapsed = max(0, now.timeIntervalSince(started.at))
            return Live(
                run: run,
                title: started.payload["input"]?["text"]?.string
                    ?? started.payload["title"]?.string ?? run,
                doing: ledger.status[run], elapsed: elapsed,
                progress: typical.map { $0 > 0 ? min(0.95, elapsed / $0) : 0.95 })
        }
        let last = ledger.runs.last { ledger.finished[$0.run ?? ""] != nil }.flatMap {
            ledger.finished[$0.run ?? ""]
        }
        return OutcomeNow(
            live: live, next: "Next run " + wake.text(now: now),
            last: last.map {
                ($0.payload["summary"]?.string ?? "Last run") + " · "
                    + AryaTime.label($0.at, now: now, style: .long)
            })
    }
}

/// A line that needs attention or explains a change, derived from the ledger.
struct OutcomeFinding: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable { case attention, negative, positive, info }
    var kind: Kind
    var text: String
    var id: String { text }

    static func build(
        events: [FeatureEvent], steward: String, state: OutcomeState, recap: OutcomeRecap,
        now: Date
    ) -> [OutcomeFinding] {
        var out: [OutcomeFinding] = []
        let week = state.points.filter { $0.day >= now.addingTimeInterval(-7 * day) }
        if let metric = state.metric, let target = metric.target, !week.isEmpty {
            let below = week.filter {
                metric.direction == .up ? $0.value < target : $0.value > target
            }
            if !below.isEmpty {
                out.append(
                    OutcomeFinding(
                        kind: .negative,
                        text: "\(metric.name) missed its target on \(below.count) of the last "
                            + "\(week.count) days"))
            }
            if let first = week.first?.value, let last = week.last?.value, week.count >= 2,
                abs(last - first) >= 0.01
            {
                let better = metric.direction == .up ? last > first : last < first
                out.append(
                    OutcomeFinding(
                        kind: better ? .positive : .negative,
                        text: "\(metric.name) \(last > first ? "rose" : "fell") from "
                            + "\(MetricText.value(first)) to \(MetricText.value(last)) this week"))
            }
        }
        let ledger = OutcomeLedger(events: events, steward: steward)
        let waiting = Set(recap.pending.map(\.approval))
        let held = ledger.holds.filter {
            waiting.contains($0.payload["approval"]?.string ?? $0.payload["id"]?.string ?? "")
        }
        if !recap.pending.isEmpty, let oldest = (held.isEmpty ? ledger.holds : held).map(\.at).min()
        {
            let count = recap.pending.count
            out.append(
                OutcomeFinding(
                    kind: .attention,
                    text: "\(count) \(count == 1 ? "approval waits" : "approvals wait") on you, "
                        + "the oldest since \(AryaTime.label(oldest, now: now, style: .long))"))
        }
        let failed = ledger.finished.values.filter {
            $0.at >= now.addingTimeInterval(-7 * day)
                && !["completed", "succeeded"].contains($0.payload["status"]?.string ?? "completed")
        }
        if !failed.isEmpty {
            out.append(
                OutcomeFinding(
                    kind: .negative,
                    text: "\(failed.count) \(failed.count == 1 ? "run" : "runs") failed this week"))
        }
        for event in events where event.steward == steward && event.type == "routine.proposed" {
            if let reason = event.payload["reason"]?.string {
                out.append(OutcomeFinding(kind: .info, text: reason))
            }
        }
        let list = ChangeList.build(events: events, steward: steward)
        for item in list.open {
            let review = ProposalReview.build(item, events: events)
            if !review.worse.isEmpty {
                out.append(
                    OutcomeFinding(
                        kind: .attention,
                        text: "A proposed change made "
                            + review.worse.map(\.id).joined(separator: ", ")
                            + " worse in rehearsal"))
            }
        }
        return out
    }
}

/// IMPACT: each action kind's estimated share of the metric's moves. Every change between two
/// readings is split evenly over the kinds executed in between; the sum per kind is its credit.
struct OutcomeImpact: Hashable, Sendable {
    struct Row: Hashable, Sendable, Identifiable {
        var kind: String
        var credit: Double
        var actions: Int
        var id: String { kind }
    }

    var rows: [Row]
    var readings: Int
    var direction: MetricDefinition.Direction

    static let limit = 5

    static func build(events: [FeatureEvent], steward: String, metric: MetricDefinition?)
        -> OutcomeImpact?
    {
        guard let metric else { return nil }
        let ledger = OutcomeLedger(events: events, steward: steward)
        let readings = ledger.metrics.filter { $0.payload["metric"]?.string == metric.name }
        guard readings.count >= 2 else { return nil }
        var credit: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for (before, after) in zip(readings, readings.dropFirst()) {
            guard let from = before.payload["value"]?.number,
                let to = after.payload["value"]?.number
            else { continue }
            let between = ledger.executed.filter { $0.seq > before.seq && $0.seq <= after.seq }
            let kinds = between.compactMap(ledger.kind)
            guard !kinds.isEmpty else { continue }
            let distinct = Set(kinds)
            for kind in distinct {
                credit[kind, default: 0] += (to - from) / Double(distinct.count)
            }
            for kind in kinds { counts[kind, default: 0] += 1 }
        }
        let good: (Double) -> Double = { metric.direction == .up ? $0 : -$0 }
        let rows = credit.map { Row(kind: $0.key, credit: $0.value, actions: counts[$0.key] ?? 0) }
            .sorted { good($0.credit) > good($1.credit) }
        guard !rows.isEmpty else { return nil }
        return OutcomeImpact(
            rows: Array(rows.prefix(limit)), readings: readings.count, direction: metric.direction)
    }

    func helped(_ row: Row) -> Bool { direction == .up ? row.credit >= 0 : row.credit <= 0 }
}

// MARK: - Views

/// The outcome over 30 days with its target, beside the operating series.
struct OutcomeMetricsPanel: View {
    let metrics: OutcomeMetrics
    let now: Date

    var body: some View {
        OutcomeSection("Metrics", trailing: "\(OutcomeMetrics.windowDays) days") {
            HStack(alignment: .top, spacing: AryaSpace.s5) {
                chart.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(metrics.series) { row($0) }
                }
                .frame(width: AryaSize.outcomeSeriesWidth)
            }
            .padding(.top, AryaSpace.s1)
        }
    }

    @ViewBuilder private var chart: some View {
        let values = metrics.points.map(\.value)
        if values.count >= 2 {
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack(alignment: .top, spacing: AryaSpace.s2) {
                    VStack(alignment: .trailing) {
                        Text(MetricText.value(axis.high)).aryaText(
                            AryaFont.monoSmall, AryaColor.inkFaint)
                        Spacer(minLength: 0)
                        Text(MetricText.value(axis.low)).aryaText(
                            AryaFont.monoSmall, AryaColor.inkFaint)
                    }
                    OutcomeSparkline(
                        values: values, target: metrics.metric?.target,
                        height: AryaSize.outcomeChartHeight)
                }
                .frame(height: AryaSize.outcomeChartHeight)
                HStack {
                    Text(metrics.points.first.map { AryaTime.label($0.day, now: now) } ?? "")
                    Spacer()
                    if let target = metrics.metric?.target {
                        Text("target \(MetricText.value(target))")
                    }
                    Spacer()
                    Text(metrics.points.last.map(lastLabel) ?? "")
                }
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OutcomeDashboardText.chart(metrics))
        } else {
            Text("Fewer than two days measured; the chart starts with the second reading.")
                .aryaText(AryaFont.caption, AryaColor.inkFaint)
        }
    }

    private func lastLabel(_ point: MetricPoint) -> String {
        now.timeIntervalSince(point.day) < day ? "today" : AryaTime.label(point.day, now: now)
    }

    private var axis: (low: Double, high: Double) {
        let values = metrics.points.map(\.value) + [metrics.metric?.target].compactMap { $0 }
        return (values.min() ?? 0, values.max() ?? 1)
    }

    private func row(_ series: OutcomeSeries) -> some View {
        HStack(alignment: .center, spacing: AryaSpace.s2) {
            Text(series.name).aryaText(AryaFont.caption, AryaColor.inkMuted)
                .lineLimit(1)
                .frame(width: AryaSize.outcomeSeriesLabel, alignment: .leading)
            OutcomeSparkline(
                values: series.values, target: nil, height: AryaSize.outcomeSeriesSpark)
            Text(series.value)
                .aryaText(AryaFont.monoSmall, color(series.tone))
                .monospacedDigit()
                .frame(width: AryaSize.outcomeSeriesValue, alignment: .trailing)
        }
        .frame(height: AryaSize.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(series.name): \(series.value)")
    }

    private func color(_ tone: OutcomeSeries.Tone) -> Color {
        switch tone {
        case .plain: AryaColor.ink
        case .attention: AryaColor.accent
        case .negative: AryaColor.negative
        }
    }
}

/// Runs in progress with a bar each, else when the next one starts and how the last ended.
struct OutcomeNowSection: View {
    let now: OutcomeNow
    let openRun: (String) -> Void

    var body: some View {
        OutcomeSection("Now", trailing: now.live.isEmpty ? nil : "\(now.live.count) running") {
            if now.live.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text("○").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    Text(now.next).aryaText(AryaFont.mono, AryaColor.ink)
                }
                .frame(height: AryaSize.rowHeight)
                if let last = now.last {
                    Text(last).aryaText(AryaFont.caption, AryaColor.inkMuted).lineLimit(1)
                        .frame(height: AryaSize.rowHeight)
                }
            }
            ForEach(now.live) { live in
                Button {
                    openRun(live.run)
                } label: {
                    VStack(alignment: .leading, spacing: AryaSpace.s1) {
                        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                            StatusDot(.running)
                            Text(live.title).aryaText(AryaFont.body, AryaColor.ink).lineLimit(1)
                            Spacer(minLength: AryaSpace.s2)
                            Text(FeatureTime.duration(live.elapsed))
                                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        }
                        if let progress = live.progress { OutcomeBar(value: progress) }
                        if let doing = live.doing {
                            Text(doing).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, AryaSpace.s1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A thin progress bar on the canvas: a hairline track and an ink fill.
struct OutcomeBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(AryaColor.rule)
                Rectangle().fill(AryaColor.accentFill)
                    .frame(width: geometry.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: AryaSize.outcomeBarHeight)
        .accessibilityLabel("About \(Int(value * 100)) percent of a typical run")
    }
}

struct OutcomeFindingsSection: View {
    let findings: [OutcomeFinding]

    var body: some View {
        OutcomeSection("Findings", trailing: findings.isEmpty ? nil : "\(findings.count)") {
            if findings.isEmpty {
                Text("Nothing stands out: on target, nothing waiting, no failures this week.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    .frame(minHeight: AryaSize.rowHeight)
            }
            ForEach(findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(mark(finding.kind)).aryaText(AryaFont.monoSmall, color(finding.kind))
                    Text(finding.text).aryaText(AryaFont.body, AryaColor.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: AryaSize.rowHeight)
            }
        }
    }

    private func mark(_ kind: OutcomeFinding.Kind) -> String {
        switch kind {
        case .attention: "◷"
        case .negative: "↓"
        case .positive: "↑"
        case .info: "·"
        }
    }

    private func color(_ kind: OutcomeFinding.Kind) -> Color {
        switch kind {
        case .attention: AryaColor.accent
        case .negative: AryaColor.negative
        case .positive: AryaColor.positive
        case .info: AryaColor.inkMuted
        }
    }
}

struct OutcomeImpactSection: View {
    let impact: OutcomeImpact

    var body: some View {
        OutcomeSection("Impact", trailing: "estimated from \(impact.readings) readings") {
            ForEach(impact.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(row.kind).aryaText(AryaFont.mono, AryaColor.ink)
                        .frame(width: AryaSize.outcomeSeriesLabel, alignment: .leading)
                    Text(OutcomeDashboardText.credit(row.credit))
                        .aryaText(
                            AryaFont.mono,
                            impact.helped(row) ? AryaColor.positive : AryaColor.negative
                        )
                        .monospacedDigit()
                    Text("over \(row.actions) \(row.actions == 1 ? "action" : "actions")")
                        .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    Spacer(minLength: 0)
                }
                .frame(height: AryaSize.rowHeight)
            }
        }
    }
}

/// Text for the dashboard, kept apart from layout so it can be tested.
enum OutcomeDashboardText {
    /// "+0.12", "−0.03".
    static func credit(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + MetricText.value(abs(value))
    }

    static func chart(_ metrics: OutcomeMetrics) -> String {
        let name = metrics.metric?.name ?? "The metric"
        guard let first = metrics.points.first?.value, let last = metrics.points.last?.value else {
            return "\(name): not enough readings."
        }
        var text = "\(name) over \(metrics.points.count) days, from \(MetricText.value(first)) "
        text += "to \(MetricText.value(last))"
        if let target = metrics.metric?.target { text += ", target \(MetricText.value(target))" }
        return text + "."
    }
}

extension AryaSize {
    static let outcomeChartHeight: CGFloat = 112
    static let outcomeSeriesWidth: CGFloat = 300
    static let outcomeSeriesLabel: CGFloat = 96
    static let outcomeSeriesSpark: CGFloat = 14
    static let outcomeSeriesValue: CGFloat = 64
    static let outcomeBarHeight: CGFloat = 2
}
