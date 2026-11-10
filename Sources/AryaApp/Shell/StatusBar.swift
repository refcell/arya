import Arya
import AryaDesign
import SwiftUI

/// The status bar's facts, built from the shell's state so they are testable: the schedule,
/// the fleet, approvals waiting, the ledger's integrity, and today's spend.
struct StatusBarLine: Equatable {
    var schedule: String
    var stewards: String
    var waiting: Int
    var ledger: String
    var ledgerOK: Bool
    var cost: String
    /// The runs going now, oldest first.
    var live: [LiveLine] = []
    /// The newest event worth reading: "3m · run.decision · Refund follow-up".
    var ticker: Ticker? = nil

    struct Ticker: Equatable {
        var id: String
        var text: String
    }

    /// Ledger noise the ticker skips: raw adapter lines and bookkeeping.
    static let quiet: Set<String> = ["run.adapter.event", "metric.recorded"]

    /// The runs going now, oldest first: only what workspace `liveRuns()` reports.
    static func lines(live: [LiveLine]) -> [LiveLine] {
        live.sorted { $0.started < $1.started }
    }

    /// The stewards with a run going now. The one source of "running" for the rail, status
    /// bar, inspector, and portfolio: workspace `liveRuns()` (lease-held runs only), never a
    /// run's recorded status, which stays `running` on runs a stopped process left behind.
    static func running(_ live: [LiveLine]) -> Set<String> { Set(live.map(\.steward)) }

    /// "Support inbox triage running · step 3 · 4.0 s · +1 more" for the newest live run.
    static func live(_ lines: [LiveLine], now: Date) -> String? {
        guard let line = lines.last else { return nil }
        let more = lines.count > 1 ? " · +\(lines.count - 1) more" : ""
        let seconds = line.elapsed(at: now)
        let estimate = line.estimatedSteps.map { " of ~\($0)" } ?? ""
        let steps = "step \(max(line.steps, 1))\(estimate)"
        return "\(line.name) running · \(steps) · \(FeatureTime.duration(seconds))\(more)"
    }

    static func ticker(stewards: [StewardSummary], events: [FeatureEvent], now: Date) -> Ticker? {
        guard let event = events.last(where: { !quiet.contains($0.type) }) else { return nil }
        let name = stewards.first { $0.id == event.steward }?.name
        let text = [AryaTime.label(event.at, now: now), event.type, name].compactMap { $0 }
            .joined(separator: " · ")
        return Ticker(id: event.id, text: text)
    }

    static func build(
        stewards: [StewardSummary], runs: [String: [RunSummary]], waiting: Int,
        events: [FeatureEvent], check: LedgerCheck?, now: Date, serve: FeatureServe? = nil,
        timeZone: TimeZone = .current, liveRuns: [LiveLine] = [], fleet: [String: String] = [:]
    ) -> StatusBarLine {
        var next: Date?
        var behind = 0
        for steward in stewards where steward.status == .active {
            let state = OutcomeState.build(
                events: events, steward: steward.id, now: now, serve: serve)
            if case .at(let date) = state.wake { next = min(next ?? date, date) }
            let series = MetricSeries.build(events: events, steward: steward.id)
            if StatusMapping.isBehind(steward, fleet: fleet, meetsTarget: series?.meetsTarget) {
                behind += 1
            }
        }
        let paused = stewards.filter { $0.status == .paused }.count
        var fleet = [stewards.count == 1 ? "1 steward" : "\(stewards.count) stewards"]
        if behind > 0 { fleet.append("\(behind) behind") }
        if paused > 0 { fleet.append("\(paused) paused") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = runs.values.joined()
            .filter { calendar.isDate($0.startedAt, inSameDayAs: now) }
            .reduce(0) { $0 + $1.costMicros }
        let ledger: String
        switch check {
        case .some(let check) where check.ok: ledger = "✓ verified \(check.events)"
        case .some(let check):
            ledger = "✕ broken at \(check.firstBadSeq.map(String.init) ?? "?")"
        case nil: ledger = "\(events.count) events"
        }
        return StatusBarLine(
            schedule: next.map {
                let time = AryaTime.upcoming($0, now: now, timeZone: timeZone)
                return serve?.serving == false ? "next due \(time)" : "next run \(time)"
            }
                ?? "no scheduled runs",
            stewards: fleet.joined(separator: " · "), waiting: waiting, ledger: ledger,
            ledgerOK: check?.ok ?? true,
            cost: today > 0 ? "\(RunMetrics.dollars(today)) today" : "spend — today",
            live: lines(live: liveRuns),
            ticker: ticker(stewards: stewards, events: events, now: now))
    }

    /// The scheduler cell, from workspace `serveState().reason` only: "scheduler" while a
    /// scheduler holds the home's lock, "serving · runs" while only leased runs drive it,
    /// "stopped" when nothing serves, "scheduler —" when the source cannot tell.
    static func scheduler(reason: String?) -> String {
        switch reason {
        case "scheduler": "scheduler"
        case "runs": "serving · runs"
        case "off": "stopped"
        default: "scheduler —"
        }
    }
}

/// A 22 pt line along the window's bottom on the same canvas, a hairline above it, in small
/// mono: schedule, fleet, approvals waiting, ledger integrity, today's spend.
struct StatusBar: View {
    let model: AppModel
    let now: Date

    var body: some View {
        let line = StatusBarLine.build(
            stewards: model.stewards, runs: model.runs, waiting: model.pendingApprovalCount,
            events: events, check: model.ledgerCheck, now: now,
            serve: model.featureStore?.serve, liveRuns: model.liveLines, fleet: model.fleetStatus)
        HStack(spacing: AryaSpace.s4) {
            Text(StatusBarLine.scheduler(reason: model.serveReason))
                .aryaText(
                    AryaFont.monoSmall,
                    model.serveReason == "off" ? AryaColor.negative : AryaColor.inkMuted
                )
                .fixedSize()
                .help("Who serves this home's triggers")
            if !line.live.isEmpty {
                // Elapsed seconds tick once a second while a run goes.
                Group {
                    if AryaMotion.frozenByProcess {
                        liveCell(line.live, now: now)
                    } else {
                        TimelineView(.periodic(from: now, by: 1)) { context in
                            liveCell(line.live, now: max(context.date, now))
                        }
                    }
                }
                .layoutPriority(1)
                .transition(.opacity)
            }
            item(line.schedule)
            item(line.stewards)
            if line.waiting > 0 {
                Button {
                    model.navigation.showApprovals()
                } label: {
                    // Orange is for the primary action only; the count reads in ink.
                    Text("• \(line.waiting) waiting on you")
                        .aryaText(AryaFont.monoSmall, AryaColor.ink)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: AryaSpace.s2)
            if let ticker = line.ticker {
                // The newest event slides in from below as it lands.
                Text(ticker.text).aryaText(AryaFont.monoSmall, AryaColor.inkMuted).lineLimit(1)
                    .id(ticker.id)
                    // The first cell to give way: counts never truncate before it.
                    .layoutPriority(-1)
                    .transition(.push(from: .bottom))
                    .help("Newest event in the ledger")
            }
            Text(line.ledger)
                .aryaText(
                    AryaFont.monoSmall, line.ledgerOK ? AryaColor.inkFaint : AryaColor.negative
                )
                .fixedSize()
                .help(model.ledgerCheck?.lines?.joined(separator: "\n") ?? "Ledger chain check")
            item(line.cost)
            Button {
                model.paletteOpen = true
            } label: {
                HStack(spacing: AryaSpace.s1) {
                    Text("Commands").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    Keycap("⌘K")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AryaSpace.s3)
        .frame(height: AryaSize.statusBarHeight)
        .frame(maxWidth: .infinity)
        .aryaHairline(edge: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
        .animation(AryaMotion.panel, value: line.ticker)
        .animation(AryaMotion.panel, value: line.live.isEmpty)
        .clipped()
    }

    private var events: [FeatureEvent] {
        guard case .loaded(let events) = model.featureStore?.state else { return [] }
        return events
    }

    private func liveCell(_ live: [LiveLine], now: Date) -> some View {
        HStack(spacing: AryaSpace.s1) {
            AryaLiveDot()
            Text(StatusBarLine.live(live, now: now) ?? "")
                .aryaText(AryaFont.monoSmall, AryaColor.positive).lineLimit(1)
            if let progress = live.last?.progress {
                AryaProgressBar(progress).frame(width: 40)
            }
        }
    }

    private func item(_ text: String) -> some View {
        Text(text).aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1).fixedSize()
    }
}

/// A run in progress as the shell shows it (from workspace `liveRuns`, or projected).
struct LiveLine: Equatable, Sendable {
    var run: String
    var steward: String
    var name: String
    var steps: Int
    var lastStep: String?
    var progress: Double?
    var started: Date
    /// `liveRuns().elapsedSeconds` as read at `readAt`; the cell adds the seconds since.
    var elapsedSeconds: Double? = nil
    var readAt: Date? = nil
    /// The steward's usual steps per run, when known.
    var estimatedSteps: Int? = nil

    /// Seconds running at `now`: the workspace's elapsed plus the time since it was read.
    func elapsed(at now: Date) -> Double {
        guard let elapsedSeconds, let readAt else { return max(0, now.timeIntervalSince(started)) }
        return max(0, elapsedSeconds + now.timeIntervalSince(readAt))
    }
}
