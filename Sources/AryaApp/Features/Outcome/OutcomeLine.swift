import AryaDesign
import SwiftUI

/// The steward's outcome on one line, shared above every steward tab: the KPI in large mono
/// against its target, a sparkline, a status pill, and the pane's one primary action.
/// The shell places it under the steward's name (`FeatureRegistry.outcomeLine`).
struct OutcomeLine: View {
    @ObservedObject var store: FeatureStore
    let steward: String
    /// Opens the approvals waiting on the person.
    let review: () -> Void
    /// Starts a manual run.
    let runNow: () -> Void

    var body: some View {
        if case .loaded(let events) = store.state,
            let live = LiveCharter.find(events: events, steward: steward)
        {
            let state = OutcomeState.build(events: events, steward: steward, now: store.now)
                .applying(store.outcomeReads[steward])
            let waiting = StewardOverview.build(events: events, steward: steward).waitingApprovals
            OutcomeLineContent(
                state: state, waiting: waiting, review: review, runNow: runNow,
                owner: OutcomeLineContent.owner(live.charter, events: events, steward: steward)
            )
            .task(id: "\(steward):\(events.count)") { await loadHeadline() }
        }
    }

    /// The header's own reads on any tab: the metric statuses and the window's missed line.
    private func loadHeadline() async {
        let metrics = try? await store.workspace.metricStatuses(
            steward: steward, windows: OutcomeMetrics.seriesDays)
        let missed: String?? =
            if let read = try? await store.workspace.outcomeMissedText(steward: steward) {
                .some(read)
            } else {
                nil
            }
        var reads = store.outcomeReads[steward] ?? OutcomeReads()
        reads.metrics = metrics ?? reads.metrics
        reads.missedText = missed ?? reads.missedText
        if reads != store.outcomeReads[steward] { store.outcomeReads[steward] = reads }
    }
}

/// The line itself, for a loaded steward.
struct OutcomeLineContent: View {
    let state: OutcomeState
    let waiting: Int
    let review: () -> Void
    let runNow: () -> Void
    /// "Maya": who answers for the outcome, by name; nil when the charter names no one.
    var owner: String? = nil

    /// The charter's owner by name: "person:maya" reads "Maya".
    static func owner(_ charter: FeatureJSON, events: [FeatureEvent], steward: String) -> String? {
        guard let owner = charter["owner"]?.string, !owner.isEmpty else { return nil }
        return HumanText.actor(owner)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            line
            if let why = state.why {
                // Why the pill says what it says, whole and in the workspace's words, on its
                // own line under the KPI.
                Text(why).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(state.reason ?? why)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OutcomeText.spoken(state))
    }

    private var line: some View {
        HStack(alignment: .center, spacing: AryaSpace.s4) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(state.latest.map(MetricText.value) ?? "—")
                    .aryaText(AryaFont.metric, AryaColor.ink)
                if let target = state.metric?.target {
                    Text("/ \(MetricText.value(target))")
                        .aryaText(AryaFont.mono, AryaColor.inkFaint)
                }
                Text(state.metric?.name ?? "no metric")
                    .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                    .lineLimit(1)
            }
            .fixedSize()
            if state.trend.count >= 2 {
                OutcomeSparkline(values: state.trend, target: state.metric?.target)
                    .frame(maxWidth: AryaSize.outcomeSparklineWidth)
            }
            OutcomeStatusPill(status: state.status)
                .help(state.reason ?? state.status.word)
            if let owner {
                Text("owned by \(owner)").aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .lineLimit(1)
                    .help("\(owner) answers for this outcome.")
            }
            Spacer(minLength: AryaSpace.s4)
            if waiting > 0 {
                Button(OutcomeText.review(waiting), action: review).buttonStyle(.aryaPrimary)
                    .fixedSize()
            } else {
                Button("Run now", action: runNow).buttonStyle(.aryaSecondary).fixedSize()
            }
        }
    }
}

extension AryaSize {
    /// The outcome line's sparkline width.
    static let outcomeSparklineWidth: CGFloat = 160
}
