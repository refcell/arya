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
            LiveCharter.find(events: events, steward: steward) != nil
        {
            let state = OutcomeState.build(events: events, steward: steward, now: store.now)
            let waiting = StewardOverview.build(events: events, steward: steward).waitingApprovals
            OutcomeLineContent(state: state, waiting: waiting, review: review, runNow: runNow)
        }
    }
}

/// The line itself, for a loaded steward.
struct OutcomeLineContent: View {
    let state: OutcomeState
    let waiting: Int
    let review: () -> Void
    let runNow: () -> Void

    var body: some View {
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
            if state.points.count >= 2 {
                OutcomeSparkline(values: state.points.map(\.value), target: state.metric?.target)
                    .frame(maxWidth: AryaSize.outcomeSparklineWidth)
            }
            OutcomeStatusPill(status: state.status)
            Spacer(minLength: AryaSpace.s4)
            if waiting > 0 {
                Button(OutcomeText.review(waiting), action: review).buttonStyle(.aryaPrimary)
            } else {
                Button("Run now", action: runNow).buttonStyle(.aryaSecondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OutcomeText.spoken(state))
    }
}

extension AryaSize {
    /// The outcome line's sparkline width.
    static let outcomeSparklineWidth: CGFloat = 160
}
