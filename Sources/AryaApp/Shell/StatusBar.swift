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
    /// "Support inbox triage running · step 3" while a run goes; nil when idle.
    var live: String? = nil
    /// The newest event worth reading: "3m · run.decision · Refund follow-up".
    var ticker: Ticker? = nil

    struct Ticker: Equatable {
        var id: String
        var text: String
    }

    /// Ledger noise the ticker skips: raw adapter lines and bookkeeping.
    static let quiet: Set<String> = ["run.adapter.event", "metric.recorded"]

    static func live(
        stewards: [StewardSummary], runs: [String: [RunSummary]], events: [FeatureEvent]
    )
        -> String?
    {
        let going = stewards.flatMap { steward in
            (runs[steward.id] ?? []).filter { $0.status == .running }.map { (steward, $0) }
        }
        guard let (steward, run) = going.max(by: { $0.1.startedAt < $1.1.startedAt }) else {
            return nil
        }
        let steps = RunStream.build(events: events, run: run.id).steps.count
        let more = going.count > 1 ? " · +\(going.count - 1) more" : ""
        return "\(steward.name) running · step \(max(steps, 1))\(more)"
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
        events: [FeatureEvent], check: LedgerCheck?, now: Date, timeZone: TimeZone = .current
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
            live: live(stewards: stewards, runs: runs, events: events),
            ticker: ticker(stewards: stewards, events: events, now: now))
    }

    /// "serving" while a process fires this home's triggers, "scheduler stopped" when none
    /// does, "scheduler —" when the source cannot tell.
    static func scheduler(_ serving: Bool?) -> String {
        switch serving {
        case true?: "serving"
        case false?: "scheduler stopped"
        case nil: "scheduler —"
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
            events: events, check: model.ledgerCheck, now: now)
        HStack(spacing: AryaSpace.s4) {
            item(StatusBarLine.scheduler(model.serving))
            if let live = line.live {
                HStack(spacing: AryaSpace.s1) {
                    AryaLiveDot()
                    Text(live).aryaText(AryaFont.monoSmall, AryaColor.positive).lineLimit(1)
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
        .animation(AryaMotion.panel, value: line.live)
        .clipped()
    }

    private var events: [FeatureEvent] {
        guard case .loaded(let events) = model.featureStore?.state else { return [] }
        return events
    }

    private func item(_ text: String) -> some View {
        Text(text).aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
    }
}
