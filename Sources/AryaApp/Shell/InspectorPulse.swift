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
    /// Workspace `runHistory().line`, "14 runs in 7 days, 2 today", shown verbatim.
    var runsLine: String = ""
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
        history: RunHistory? = nil, timeZone: TimeZone = .current
    ) -> StewardPulse {
        let series = MetricSeries.build(events: events, steward: steward.id)
        var value = "—"
        if let definition = series?.definition {
            value = MetricText.figure(
                series?.latest?.value, target: definition.target,
                offTarget: series?.meetsTarget == false)
        }
        // Bars from workspace `runHistory` only: live top-level runs, rehearsals apart.
        let totals = history?.days.map(\.runs) ?? []
        let failed = history?.days.map(\.failed) ?? []
        // One source and one format with NOW and the status bar (app-outcome).
        let state = OutcomeState.build(
            events: events, steward: steward.id, now: now, serve: serve)
        // The next wake from `stewardLive` when read, as NOW shows it (one source).
        var wake = state.wake
        var serving = state.serving
        if let stewardLive, wake != .paused {
            serving = stewardLive.serving
            if stewardLive.schedule == "unscheduled" {
                wake = .onDemand
            } else if let date = stewardLive.nextWake?.date {
                wake = .at(date)
            }
        }
        let next: String
        switch wake {
        case .paused: next = "paused"
        case .onDemand: next = "on demand"
        case .at(let date):
            let time = AryaTime.upcoming(date, now: now, timeZone: timeZone)
            next = serving == false ? "due \(time)" : time
        }
        return StewardPulse(
            metricName: series?.definition.name, metricValue: value,
            series: (series?.points ?? []).suffix(14).map(\.value),
            behind: StatusMapping.isBehind(steward, fleet: fleet, meetsTarget: series?.meetsTarget),
            runsPerDay: totals, runsLine: history?.line ?? "", failedPerDay: failed,
            costToday: costToday(runs, now: now, timeZone: timeZone),
            nextWake: steward.status == .paused ? "paused" : next,
            // Workspace `stewardLive` when read, else its `liveRuns()` (the same tally).
            running: stewardLive.map { ($0.running == nil ? 0 : 1) + $0.alsoRunning }
                ?? live.filter { $0.steward == steward.id }.count,
            approvals: approvals.filter { $0.steward == steward.id },
            decisions: OutcomeContext.build(events: events, steward: steward.id).decisions)
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
        events: [FeatureEvent], live: [LiveLine] = [], fleet: [String: String] = [:],
        history: RunHistory? = nil, now: Date, timeZone: TimeZone = .current
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
        return FleetPulse(
            onTrack: onTrack, behind: behind, paused: paused, waiting: approvals.count,
            runsPerDay: history?.days.map(\.runs) ?? [],
            failedPerDay: history?.days.map(\.failed) ?? [], runsToday: history?.today ?? 0,
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
    /// Top-level runs to list under the pulse, newest first; empty lists none (Needs you
    /// passes them, where the column has room).
    var recentRuns: [RunSummary] = []
    var now = Date()
    var title: (RunSummary) -> String = { StatusMapping.threadTitle(of: $0) }
    var openRun: ((RunSummary) -> Void)? = nil
    let openApproval: (String) -> Void

    /// Runs the Needs you inspector lists.
    static let recentLimit = 10

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
                    Text(pulse.runsLine).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        .lineLimit(1)
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
                                    ActionWords.sentence(
                                        kind: approval.actionKind ?? approval.kind.rawValue,
                                        target: approval.target ?? "")
                                )
                                .aryaText(AryaFont.caption, AryaColor.ink)
                                .lineLimit(1)
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
            if !recentRuns.isEmpty { recent }
        }
    }
}

extension StewardPulseView {
    /// The steward's latest runs: age, a pass or fail dot, and the title; a click opens it.
    fileprivate var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent runs").aryaText(AryaFont.label, AryaColor.inkFaint)
                .frame(height: AryaSize.rowHeight)
            ForEach(recentRuns.prefix(Self.recentLimit)) { run in
                Button {
                    openRun?(run)
                } label: {
                    HStack(spacing: AryaSpace.s2) {
                        StatusDot(Self.state(run))
                        Text(title(run)).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(1)
                        Spacer(minLength: AryaSpace.s2)
                        Text(ThreadRow.shortTime(run.startedAt, now: now))
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    }
                    .frame(height: AryaSize.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(openRun == nil)
                .help(title(run))
            }
        }
    }

    static func state(_ run: RunSummary) -> AryaStatus {
        switch run.status {
        case .running: .running
        case .failed: .failed
        case .finished: .done
        }
    }
}

/// The fleet pulse: the All stewards inspector.
struct FleetPulseView: View {
    /// One approval waiting on a person, oldest first.
    struct Waiting: Identifiable, Equatable {
        var id: String
        var steward: String
        var text: String
        var age: String
    }

    let pulse: FleetPulse
    var departments: [PortfolioDepartments.Line] = []
    var waiting: [Waiting] = []
    let open: (String) -> Void
    var openApproval: (String) -> Void = { _ in }

    static let countWidth: CGFloat = 16
    static let waitingWidth: CGFloat = 64
    static let behindWidth: CGFloat = 60

    /// The oldest approvals across the fleet, at most `limit`.
    static func waiting(
        _ approvals: [ApprovalSummary], names: [String: String], now: Date, limit: Int = 6
    ) -> [Waiting] {
        approvals.sorted { $0.requestedAt < $1.requestedAt }.prefix(limit).map { approval in
            Waiting(
                id: approval.id, steward: names[approval.steward] ?? approval.steward,
                text: approval.actionKind.map {
                    ActionWords.sentence(kind: $0, target: approval.target ?? "")
                } ?? approval.text,
                age: ThreadRow.shortTime(approval.requestedAt, now: now))
        }
    }

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
            if !departments.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("By department").aryaText(AryaFont.label, AryaColor.inkFaint)
                        .frame(height: AryaSize.rowHeight)
                    ForEach(departments) { line in
                        HStack(spacing: AryaSpace.s2) {
                            Text(line.id).aryaText(AryaFont.caption, AryaColor.ink).lineLimit(1)
                            if line.running > 0 { AryaLiveDot() }
                            Spacer(minLength: AryaSpace.s2)
                            Text("\(line.stewards)").aryaText(
                                AryaFont.monoSmall, AryaColor.inkFaint
                            )
                            .frame(width: Self.countWidth, alignment: .trailing)
                            Text(line.waiting > 0 ? "\(line.waiting) waiting" : "")
                                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                                .frame(width: Self.waitingWidth, alignment: .trailing)
                            Text(line.behind > 0 ? "\(line.behind) behind" : "")
                                .aryaText(AryaFont.monoSmall, AryaColor.negative)
                                .frame(width: Self.behindWidth, alignment: .trailing)
                        }
                        .frame(height: AryaSize.rowHeight)
                    }
                }
            }
            if !waiting.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Oldest waiting").aryaText(AryaFont.label, AryaColor.inkFaint)
                        .frame(height: AryaSize.rowHeight)
                    ForEach(waiting) { item in
                        Button {
                            openApproval(item.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.text).aryaText(AryaFont.caption, AryaColor.ink)
                                        .lineLimit(1)
                                    Text(item.steward)
                                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                                }
                                Spacer(minLength: AryaSpace.s2)
                                Text(item.age).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                            }
                            .padding(.vertical, AryaSpace.s1)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.text)
                    }
                }
            }
        }
    }
}
