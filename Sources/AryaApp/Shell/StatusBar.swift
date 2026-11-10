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

    /// The runs going now: the workspace's live runs when it reports them, else the running
    /// summaries with step counts projected from the ledger.
    static func lines(
        live: [LiveLine], stewards: [StewardSummary], runs: [String: [RunSummary]],
        events: [FeatureEvent]
    ) -> [LiveLine] {
        if !live.isEmpty { return live }
        return stewards.flatMap { steward in
            (runs[steward.id] ?? []).filter { $0.status == .running }.map { run in
                LiveLine(
                    run: run.id, steward: steward.id, name: steward.name,
                    steps: RunStream.build(events: events, run: run.id).steps.count,
                    lastStep: nil, progress: nil, started: run.startedAt)
            }
        }
        .sorted { $0.started < $1.started }
    }

    /// "Support inbox triage running · step 3 · 4.0 s · +1 more" for the newest live run.
    static func live(_ lines: [LiveLine], now: Date) -> String? {
        guard let line = lines.last else { return nil }
        let more = lines.count > 1 ? " · +\(lines.count - 1) more" : ""
        let seconds = max(0, now.timeIntervalSince(line.started))
        let steps = "step \(max(line.steps, 1))"
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
        events: [FeatureEvent], check: LedgerCheck?, now: Date, timeZone: TimeZone = .current,
        liveRuns: [LiveLine] = []
    ) -> StatusBarLine {
        var next: Date?
        var behind = 0
        for steward in stewards where steward.status == .active {
            let state = OutcomeState.build(events: events, steward: steward.id, now: now)
            if case .at(let date) = state.wake { next = min(next ?? date, date) }
            if MetricSeries.build(events: events, steward: steward.id)?.meetsTarget == false {
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
            schedule: next.map { "next run \(AryaTime.upcoming($0, now: now, timeZone: timeZone))" }
                ?? "no scheduled runs",
            stewards: fleet.joined(separator: " · "), waiting: waiting, ledger: ledger,
            ledgerOK: check?.ok ?? true,
            cost: today > 0 ? "\(RunMetrics.dollars(today)) today" : "spend — today",
            live: lines(live: liveRuns, stewards: stewards, runs: runs, events: events),
            ticker: ticker(stewards: stewards, events: events, now: now))
    }

    /// "serving" while a process fires this home's triggers, "scheduler stopped" when none
    /// does, "scheduler —" when the source cannot tell.
    /// Live runs mean something is serving (the demo pacer or `arya serve`).
    static func scheduler(_ serving: Bool?, live: Bool = false) -> String {
        if live { return "serving" }
        switch serving {
        case true?: return "serving"
        case false?: return "scheduler stopped"
        case nil: return "scheduler —"
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
            events: events, check: model.ledgerCheck, now: now, liveRuns: model.liveLines)
        HStack(spacing: AryaSpace.s4) {
            item(StatusBarLine.scheduler(model.serving, live: !line.live.isEmpty))
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
                    AryaFont.monoSmall, line.ledgerOK ? AryaColor.inkFaint : AryaColor.negative)
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
}
