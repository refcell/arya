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
            count("held for you", ledger.holds),
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

/// NOW: this steward's live run from `stewardLive(steward:)`, else when the next one starts.
struct OutcomeNow: Hashable, Sendable {
    struct Live: Hashable, Sendable, Identifiable {
        var run: String
        var title: String
        /// The adapter's latest step line, when it sent one.
        var doing: String?
        var elapsed: TimeInterval
        var progress: Double?
        /// "step 3 of ~7", from the workspace's step count and usual steps.
        var steps: String
        var id: String { run }
    }

    var live: [Live]
    /// Other runs of this steward in progress (crew children, overlapping wakes).
    var alsoRunning = 0
    var next: String
    var last: String?

    /// Whether "Start serving" belongs beside the next time: the scheduler is stopped.
    var stopped = false

    /// Maps the workspace's live state; without it (a home that cannot say) NOW shows only the
    /// schedule from the serve status. The last run's summary line comes from the ledger.
    static func build(
        events: [FeatureEvent], steward: String, state: OutcomeState, now: Date,
        live: FeatureStewardLive? = nil
    ) -> OutcomeNow {
        let ledger = OutcomeLedger(events: events, steward: steward)
        let running = live.flatMap { live in
            live.running.map { facts in (facts, live.run ?? "", live.title, live.progress) }
        }.map { facts, run, title, progress in
            Live(
                run: run, title: title ?? "Run in progress", doing: ledger.status[run],
                elapsed: facts.elapsedSeconds, progress: progress,
                steps: "step \(facts.stepIndex)"
                    + (facts.estimatedSteps.map { " of ~\($0)" } ?? ""))
        }
        var wake = state.wake
        var serving = state.serving
        if let live, wake != .paused {
            serving = live.serving
            if live.schedule == "unscheduled" {
                wake = .onDemand
            } else if let date = live.nextWake {
                wake = .at(date)
            }
        }
        let last = ledger.runs.last { ledger.finished[$0.run ?? ""] != nil }.flatMap {
            ledger.finished[$0.run ?? ""]
        }
        return OutcomeNow(
            live: running.map { [$0] } ?? [], alsoRunning: live?.alsoRunning ?? 0,
            next: wake.schedule(now: now, serving: serving),
            last: last.map {
                ($0.payload["summary"]?.string ?? "Last run") + " · "
                    + AryaTime.label($0.at, now: now, style: .long)
            }, stopped: serving == false && wake != .paused)
    }
}

/// A FINDINGS line, from `overviewFindings(steward:)`.
struct OutcomeFinding: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable { case attention, negative, positive, info }
    var kind: Kind
    var text: String
    var id: String { text }

    /// Maps the workspace's lines, plain words for charter versions, severity first: harm,
    /// then what waits on you, then good news, then notes.
    static func build(
        _ lines: [FeatureOverviewFinding], events: [FeatureEvent], steward: String
    ) -> [OutcomeFinding] {
        let rank: [Kind: Int] = [.negative: 0, .attention: 1, .positive: 2, .info: 3]
        return lines.map { line -> OutcomeFinding in
            // A proposal that regressed in rehearsal is harm the person must see first.
            let kind: Kind =
                switch line.kind {
                case _ where line.link == "proposal": .negative
                case "problem", "negative": .negative
                case "attention": .attention
                case "opportunity", "positive": .positive
                default: .info
                }
            return OutcomeFinding(
                kind: kind,
                text: OutcomeDashboardText.plain(line.text, events: events, steward: steward))
        }
        .enumerated().sorted {
            let (left, right) = (rank[$0.element.kind] ?? 9, rank[$1.element.kind] ?? 9)
            return left != right ? left < right : $0.offset < $1.offset
        }.map(\.element)
    }
}

/// IMPACT, from `impact(steward:)`: credit per action kind with the workspace's confidence,
/// or its one honest line when nothing splits.
struct OutcomeImpact: Hashable, Sendable {
    struct Row: Hashable, Sendable, Identifiable {
        var label: String
        var credit: Double
        var helped: Bool
        /// "12 actions in 5 of 7 windows · medium confidence".
        var detail: String
        var id: String { label }
    }

    var rows: [Row]
    var summary: String
    var readings: Int

    static func build(_ impact: FeatureImpact) -> OutcomeImpact {
        let windows = max(0, impact.readings - 1)
        return OutcomeImpact(
            rows: impact.rows.map { row in
                let noun = row.actions == 1 ? "action" : "actions"
                return Row(
                    label: row.label, credit: row.credit, helped: row.helped,
                    detail: "\(row.actions) \(noun) in \(row.windows) of \(windows) windows · "
                        + "\(row.confidence) confidence")
            }, summary: impact.summary, readings: impact.readings)
    }

    /// Green for help, red for harm, muted for a change that rounds to zero.
    static func tone(_ row: Row) -> Color {
        if abs(row.credit) < 0.005 { return AryaColor.inkMuted }
        return row.helped ? AryaColor.positive : AryaColor.negative
    }
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
    /// Starts firing triggers from this app, offered while the scheduler is stopped.
    var startServing: (() -> Void)?

    var body: some View {
        OutcomeSection(
            "Now", trailing: now.live.isEmpty ? nil : "\(now.live.count + now.alsoRunning) running"
        ) {
            if now.live.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text("○").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    Text(now.next).aryaText(AryaFont.mono, AryaColor.ink)
                    if now.stopped, let startServing {
                        Spacer(minLength: AryaSpace.s2)
                        Button("Start serving", action: startServing)
                            .buttonStyle(.aryaSecondary)
                            .help("Fire this home's scheduled runs from the app.")
                    }
                }
                .frame(minHeight: AryaSize.rowHeight)
                if let last = now.last {
                    Text(last).aryaText(AryaFont.caption, AryaColor.inkMuted).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(last)
                        .textSelection(.enabled)
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
                            Text(live.steps).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                            Text(FeatureTime.duration(live.elapsed))
                                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        }
                        if let progress = live.progress {
                            AryaProgressBar(progress, isLive: true)
                        }
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
                Text("Nothing raised: no misses, waits, or failures to report.")
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    .frame(minHeight: AryaSize.rowHeight)
            }
            ForEach(findings) { finding in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(mark(finding.kind)).aryaText(AryaFont.monoSmall, color(finding.kind))
                    Text(finding.text).aryaText(AryaFont.body, AryaColor.ink)
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
        OutcomeSection("Impact", trailing: "from \(impact.readings) readings") {
            Text(impact.summary).aryaText(AryaFont.body, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: AryaSize.rowHeight)
            ForEach(impact.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(row.label).aryaText(AryaFont.mono, AryaColor.ink)
                        .frame(width: AryaSize.outcomeSeriesLabel, alignment: .leading)
                    Text(OutcomeDashboardText.credit(row.credit))
                        .aryaText(AryaFont.mono, OutcomeImpact.tone(row))
                        .monospacedDigit()
                    Text(row.detail).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    Spacer(minLength: 0)
                }
                .frame(height: AryaSize.rowHeight)
            }
        }
    }
}

/// Text for the dashboard, kept apart from layout so it can be tested.
enum OutcomeDashboardText {
    /// Rewrites "Version 1 missed …" into plain words: "The current charter missed …" for
    /// the live version, "Charter version 1 missed …" for an older one.
    static func plain(_ text: String, events: [FeatureEvent], steward: String) -> String {
        guard text.hasPrefix("Version ") else { return text }
        let rest = text.dropFirst("Version ".count)
        let digits = rest.prefix { $0.isNumber }
        guard let version = Int(digits) else { return text }
        let live = LiveCharter.find(events: events, steward: steward)?.version
        let lead = version == live ? "The current charter" : "Charter version \(version)"
        return lead + rest.dropFirst(digits.count)
    }

    /// "+0.12", "−0.03".
    /// "+0.17", "−0.03", or "±0.00" when it rounds to zero.
    static func credit(_ value: Double) -> String {
        if abs(value) < 0.005 { return "±" + MetricText.value(0) }
        return (value < 0 ? "−" : "+") + MetricText.value(abs(value))
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
