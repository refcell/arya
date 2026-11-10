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
            cost: today > 0 ? "\(RunMetrics.dollars(today)) today" : "spend — today")
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
    }

    private var events: [FeatureEvent] {
        guard case .loaded(let events) = model.featureStore?.state else { return [] }
        return events
    }

    private func item(_ text: String) -> some View {
        Text(text).aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
    }
}
