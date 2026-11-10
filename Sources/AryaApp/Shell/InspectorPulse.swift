import Arya
import AryaDesign
import SwiftUI

/// A steward at a glance for the top of its inspector: metric against target with its
/// trend, runs per day for a week, today's cost, the next wake as a countdown, what waits on
/// the person, and its newest decisions. Read from the ledger and the facade's summaries.
struct StewardPulse: Equatable {
    /// "routed_within_1h", nil without a metric.
    var metricName: String?
    /// "0.96 / 0.95".
    var metricValue: String
    var series: [Double]
    var behind: Bool
    /// Top-level runs per day, oldest first, today last.
    var runsPerDay: [Int]
    var failedPerDay: [Int]
    /// "$0.0042 today", "—" when no run today reported a cost.
    var costToday: String
    /// "in 2h 14m", "paused", "on demand".
    var nextWake: String
    /// Runs going right now.
    var running: Int
    var approvals: [ApprovalSummary]
    var decisions: [OutcomeContext.Line]

    static let days = 7

    static func build(
        steward: StewardSummary, runs: [RunSummary], approvals: [ApprovalSummary],
        events: [FeatureEvent], now: Date, serve: FeatureServe? = nil, live: [LiveLine] = [],
        stewardLive: StewardLive? = nil, fleet: [String: String] = [:],
        timeZone: TimeZone = .current
    ) -> StewardPulse {
        let series = MetricSeries.build(events: events, steward: steward.id)
        var value = "—"
        if let definition = series?.definition {
            let latest = series?.latest.map { StatusMapping.metric($0.value) } ?? "—"
            value = latest + (definition.target.map { " / \(StatusMapping.metric($0))" } ?? "")
        }
        let (totals, failed) = perDay(
            runs.filter { $0.parent == nil }, now: now, timeZone: timeZone)
        // One source and one format with NOW and the status bar (app-outcome).
        let state = OutcomeState.build(
            events: events, steward: steward.id, now: now, serve: serve)
        let next: String
        switch state.wake {
        case .paused: next = "paused"
        case .onDemand: next = "on demand"
        case .at(let date):
            let time = AryaTime.upcoming(date, now: now, timeZone: timeZone)
            next = state.serving == false ? "due \(time)" : time
        }
        return StewardPulse(
            metricName: series?.definition.name, metricValue: value,
            series: (series?.points ?? []).suffix(14).map(\.value),
            behind: StatusMapping.isBehind(steward, fleet: fleet, meetsTarget: series?.meetsTarget),
            runsPerDay: totals, failedPerDay: failed,
            costToday: costToday(runs, now: now, timeZone: timeZone),
            nextWake: steward.status == .paused ? "paused" : next,
            // Workspace `stewardLive` when read, else its `liveRuns()` (the same tally).
            running: stewardLive.map { ($0.running == nil ? 0 : 1) + $0.alsoRunning }
                ?? live.filter { $0.steward == steward.id }.count,
            approvals: approvals.filter { $0.steward == steward.id },
            decisions: OutcomeContext.build(events: events, steward: steward.id).decisions)
    }

    /// Runs started on each of the last `days` local days, oldest first, and the failed ones.
    static func perDay(_ runs: [RunSummary], now: Date, timeZone: TimeZone) -> ([Int], [Int]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        var totals = Array(repeating: 0, count: days)
        var failed = Array(repeating: 0, count: days)
        for run in runs {
            let day = calendar.startOfDay(for: run.startedAt)
            guard let back = calendar.dateComponents([.day], from: day, to: today).day,
                (0..<days).contains(back)
            else { continue }
            totals[days - 1 - back] += 1
            if run.status == .failed { failed[days - 1 - back] += 1 }
        }
        return (totals, failed)
    }

    /// "$0.0042 today", or "—" when no run started today reported a cost.
    static func costToday(_ runs: [RunSummary], now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let micros = runs.filter { calendar.isDate($0.startedAt, inSameDayAs: now) }
            .reduce(0) { $0 + $1.costMicros }
        return micros > 0 ? "\(RunMetrics.dollars(micros)) today" : "—"
    }

    /// "in 45 s", "in 14m", "in 2h 14m", "in 3d"; "due" once past.
    static func countdown(to date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        if seconds <= 0 { return "due" }
        if seconds < 60 { return "in \(seconds) s" }
        if seconds < 3600 { return "in \(seconds / 60)m" }
        if seconds < 86_400 { return "in \(seconds / 3600)h \(seconds % 3600 / 60)m" }
        return "in \(seconds / 86_400)d"
    }
}

/// The fleet at a glance, for the All stewards inspector.
struct FleetPulse: Equatable {
    struct Mover: Equatable, Identifiable {
        var id: String
        var name: String
        /// "+0.04", "−0.06".
        var delta: String
        /// Whether it moved toward its target's direction.
        var good: Bool
    }

    var onTrack: Int
    var behind: Int
    var paused: Int
    var waiting: Int
    var runsPerDay: [Int]
    var failedPerDay: [Int]
    var runsToday: Int
    var costToday: String
    var running: Int
    /// Largest metric moves between the last two days, biggest first, at most three.
    var movers: [Mover]

    static func build(
        stewards: [StewardSummary], runs: [String: [RunSummary]], approvals: [ApprovalSummary],
        events: [FeatureEvent], live: [LiveLine] = [], fleet: [String: String] = [:], now: Date,
        timeZone: TimeZone = .current
    ) -> FleetPulse {
        var onTrack = 0
        var behind = 0
        var paused = 0
        var movers: [(Mover, Double)] = []
        for steward in stewards {
            let series = MetricSeries.build(events: events, steward: steward.id)
            if steward.status == .paused {
                paused += 1
            } else if StatusMapping.isBehind(
                steward, fleet: fleet, meetsTarget: series?.meetsTarget)
            {
                behind += 1
            } else {
                onTrack += 1
            }
            if let points = series?.points, points.count >= 2 {
                let delta = points[points.count - 1].value - points[points.count - 2].value
                // A change that rounds to zero is not a mover ("−0.00").
                if abs(delta) >= 0.005 {
                    let sign = delta > 0 ? "+" : "−"
                    let text = sign + StatusMapping.metric(abs(delta))
                    movers.append(
                        (
                            Mover(
                                id: steward.id, name: steward.name, delta: text,
                                good: (delta > 0) == (series?.definition.direction == .up)),
                            abs(delta)
                        ))
                }
            }
        }
        let all = runs.values.flatMap { $0 }
        let top = all.filter { $0.parent == nil }
        let (totals, failed) = StewardPulse.perDay(top, now: now, timeZone: timeZone)
        return FleetPulse(
            onTrack: onTrack, behind: behind, paused: paused, waiting: approvals.count,
            runsPerDay: totals, failedPerDay: failed, runsToday: totals.last ?? 0,
            costToday: StewardPulse.costToday(all, now: now, timeZone: timeZone),
            running: StatusBarLine.running(live).count,
            movers: movers.sorted { $0.1 > $1.1 }.prefix(3).map(\.0))
    }
}

/// The figures a pulse shows: a label over a mono value, three to a row.
struct PulseFigure: View {
    let label: String
    let value: String
    var tone: Color = AryaColor.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).aryaText(AryaFont.label, AryaColor.inkFaint)
            Text(value).aryaText(AryaFont.mono, tone).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The steward pulse block at the top of the steward inspector.
struct StewardPulseView: View {
    let pulse: StewardPulse
    let openApproval: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            if let name = pulse.metricName {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(pulse.metricValue)
                            .aryaText(
                                AryaFont.metric, pulse.behind ? AryaColor.negative : AryaColor.ink)
                        Spacer(minLength: AryaSpace.s2)
                        Text(name).aryaText(AryaFont.monoSmall, AryaColor.inkMuted).lineLimit(1)
                    }
                    if pulse.series.count > 1 {
                        Sparkline(pulse.series, onTarget: !pulse.behind, width: nil, height: 32)
                    }
                }
            }
            HStack(spacing: AryaSpace.s3) {
                PulseFigure(label: "Next wake", value: pulse.nextWake)
                PulseFigure(label: "Cost today", value: pulse.costToday)
                PulseFigure(
                    label: "Running", value: pulse.running == 0 ? "idle" : "\(pulse.running)",
                    tone: pulse.running == 0 ? AryaColor.inkMuted : AryaColor.positive)
            }
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack {
                    Text("Runs · 7 days").aryaText(AryaFont.label, AryaColor.inkFaint)
                    Spacer()
                    Text("\(pulse.runsPerDay.reduce(0, +)) total")
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
                DayBars(pulse.runsPerDay, failed: pulse.failedPerDay)
            }
            if !pulse.approvals.isEmpty {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("Waiting on you · \(pulse.approvals.count)")
                        .aryaText(AryaFont.label, AryaColor.inkFaint)
                    ForEach(pulse.approvals, id: \.id) { approval in
                        Button {
                            openApproval(approval.id)
                        } label: {
                            HStack(spacing: AryaSpace.s2) {
                                StatusDot(.needsYou)
                                // The target, not the why-label (several share one).
                                Text(
                                    ActionWords.line(
                                        kind: approval.actionKind ?? approval.kind.rawValue,
                                        target: approval.target ?? "")
                                )
                                .aryaText(AryaFont.monoSmall, AryaColor.ink)
                                .lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 0)
                            }
                            .frame(height: AryaSize.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open in Needs you")
                    }
                }
            }
            if !pulse.decisions.isEmpty {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    Text("Recent decisions").aryaText(AryaFont.label, AryaColor.inkFaint)
                    ForEach(pulse.decisions) { line in
                        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                            Text(ActionWords.kind(line.key))
                                .aryaText(AryaFont.monoSmall, AryaColor.ink)
                            Text(line.text).aryaText(AryaFont.caption, AryaColor.inkMuted)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}

/// The fleet pulse: the All stewards inspector.
struct FleetPulseView: View {
    let pulse: FleetPulse
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            HStack(spacing: AryaSpace.s3) {
                PulseFigure(label: "On track", value: "\(pulse.onTrack)", tone: AryaColor.positive)
                PulseFigure(
                    label: "Behind", value: "\(pulse.behind)",
                    tone: pulse.behind > 0 ? AryaColor.negative : AryaColor.inkMuted)
                PulseFigure(label: "Paused", value: "\(pulse.paused)", tone: AryaColor.inkMuted)
            }
            HStack(spacing: AryaSpace.s3) {
                PulseFigure(label: "Waiting", value: "\(pulse.waiting)")
                PulseFigure(label: "Runs today", value: "\(pulse.runsToday)")
                PulseFigure(label: "Cost today", value: pulse.costToday)
            }
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack {
                    Text("Runs · 7 days").aryaText(AryaFont.label, AryaColor.inkFaint)
                    Spacer()
                    if pulse.running > 0 {
                        AryaLiveDot()
                        Text("\(pulse.running) running").aryaText(
                            AryaFont.monoSmall, AryaColor.positive)
                    }
                }
                DayBars(pulse.runsPerDay, failed: pulse.failedPerDay)
            }
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                Text("Top movers").aryaText(AryaFont.label, AryaColor.inkFaint)
                if pulse.movers.isEmpty {
                    Text("No metric moved since yesterday.")
                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
                ForEach(pulse.movers) { mover in
                    Button {
                        open(mover.id)
                    } label: {
                        HStack {
                            Text(mover.name).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(1)
                            Spacer(minLength: AryaSpace.s2)
                            Text(mover.delta)
                                .aryaText(
                                    AryaFont.monoSmall,
                                    mover.good ? AryaColor.positive : AryaColor.negative)
                        }
                        .frame(height: AryaSize.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
