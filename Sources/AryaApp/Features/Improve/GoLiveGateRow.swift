import AryaDesign
import SwiftUI

/// The go-live gate as one embeddable card (eval): agreed reviews, a passing rehearsal, and
/// green checks, each with a check or a cross and its detail, then the one sentence of what is
/// missing. No background of its own, so onboarding or Improve can place it anywhere.
struct GoLiveGateRow: View {
    var gate: FeatureGoLiveGate

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text("GO LIVE").aryaText(AryaFont.overline, AryaColor.inkFaint)
                Chip(
                    gate.ready ? "ready" : "not ready",
                    textColor: gate.ready ? AryaColor.positive : AryaColor.negative)
                Text(GoLiveGateText.tally(gate)).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                    .monospacedDigit()
                Spacer(minLength: AryaSpace.s2)
            }
            ForEach(gate.conditions) { condition in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    MarkGlyph(mark: condition.met ? .ok : .failed)
                        .frame(width: AryaSpace.s3)
                    Text(GoLiveGateText.title(condition.key))
                        .aryaText(AryaFont.label, AryaColor.ink)
                        .frame(minWidth: 112, alignment: .leading)
                    Text(condition.detail)
                        .aryaText(
                            AryaFont.monoSmall,
                            condition.met ? AryaColor.inkMuted : AryaColor.negative
                        )
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(GoLiveGateText.title(condition.key)): \(condition.met ? "met" : "not met"), "
                        + condition.detail)
            }
            Text(MetricText.sentence(gate.summary)).aryaText(AryaFont.body, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The go-live gate in words.
enum GoLiveGateText {
    static func title(_ key: String) -> String {
        switch key {
        case "review": "Agreed reviews"
        case "rehearsal": "Rehearsal"
        case "checks": "Learned checks"
        default: key
        }
    }

    /// `2 of 3 met`.
    static func tally(_ gate: FeatureGoLiveGate) -> String {
        "\(gate.conditions.filter(\.met).count) of \(gate.conditions.count) met"
    }
}
