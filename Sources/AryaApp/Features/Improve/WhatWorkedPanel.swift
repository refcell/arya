import AryaDesign
import SwiftUI

/// What worked on Improve (eval's trajectory grading): each run graded on the follow-up
/// checks that came days or weeks after it, then credit for the action kinds and decision
/// choices those runs took. Dense rows: name, resolved of settled, median lag, confidence.
/// Sparse evidence shows dashes and says how few outcomes there are.
struct WhatWorkedPanel: View {
    var trajectories: FeatureTrajectories
    /// Rows per group before "N more".
    var limit = 6
    @AryaState private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text("WHAT WORKED").aryaText(AryaFont.overline, AryaColor.inkFaint)
                tally
                Spacer(minLength: AryaSpace.s2)
            }
            Text(trajectories.sentence).aryaText(AryaFont.body, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            group("KINDS", trajectories.credits.filter { $0.axis == "kind" })
            group("CHOICES", trajectories.credits.filter { $0.axis == "choice" })
            if hidden > 0 || expanded {
                Button(expanded ? "Fewer" : "\(hidden) more") { expanded.toggle() }
                    .buttonStyle(.aryaTertiary)
            }
        }
    }

    /// Good in green, reopened in red, open muted; or `nothing graded yet`.
    @ViewBuilder
    private var tally: some View {
        if trajectories.good + trajectories.bad + trajectories.pending == 0 {
            Text(WhatWorkedText.tally(trajectories))
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
        } else {
            HStack(spacing: AryaSpace.s2) {
                Text("\(trajectories.good) good").aryaText(AryaFont.monoSmall, AryaColor.positive)
                Text("\(trajectories.bad) reopened")
                    .aryaText(
                        AryaFont.monoSmall,
                        trajectories.bad > 0 ? AryaColor.negative : AryaColor.inkMuted)
                if trajectories.pending > 0 {
                    Text("\(trajectories.pending) open")
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        }
    }

    private var hidden: Int {
        ["kind", "choice"].reduce(0) { total, axis in
            total + max(0, trajectories.credits.filter { $0.axis == axis }.count - limit)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ credits: [FeatureTrajectories.Credit]) -> some View {
        if !credits.isEmpty {
            Text(title).aryaText(AryaFont.overline, AryaColor.inkFaint)
                .padding(.top, AryaSpace.s1)
            ForEach(expanded ? credits : Array(credits.prefix(limit))) { credit in row(credit) }
        }
    }

    private func row(_ credit: FeatureTrajectories.Credit) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
            Text(credit.name).aryaText(AryaFont.mono, AryaColor.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 140, alignment: .leading)
            Text(WhatWorkedText.outcome(credit))
                .aryaText(AryaFont.monoSmall, WhatWorkedText.outcomeColor(credit))
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            Text(WhatWorkedText.lag(credit)).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
            Chip(
                WhatWorkedText.confidence(credit),
                textColor: WhatWorkedText.sparse(credit)
                    ? AryaColor.inkFaint : WhatWorkedText.confidenceColor(credit)
            )
            .frame(minWidth: 180, alignment: .leading)
            TrajectoryBar(
                resolved: credit.resolved, reopened: credit.reopened, open: credit.pending)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(credit.line)
        .help(credit.line)
    }
}

/// What worked in words.
enum WhatWorkedText {
    /// Settled outcomes below this read as too few to judge.
    static let enough = 3

    /// `4 good · 1 reopened · 2 open`, or `nothing graded yet`.
    static func tally(_ worked: FeatureTrajectories) -> String {
        guard worked.good + worked.bad + worked.pending > 0 else { return "nothing graded yet" }
        var parts = ["\(worked.good) good", "\(worked.bad) reopened"]
        if worked.pending > 0 { parts.append("\(worked.pending) open") }
        return parts.joined(separator: " · ")
    }

    static func tallyColor(_ worked: FeatureTrajectories) -> Color {
        worked.bad > 0
            ? AryaColor.negative : worked.good > 0 ? AryaColor.positive : AryaColor.inkMuted
    }

    static func settled(_ credit: FeatureTrajectories.Credit) -> Int {
        credit.resolved + credit.reopened
    }

    static func sparse(_ credit: FeatureTrajectories.Credit) -> Bool {
        settled(credit) < enough
    }

    /// `10/12` resolved of settled, or `—` before enough settle.
    static func outcome(_ credit: FeatureTrajectories.Credit) -> String {
        sparse(credit) ? "—" : "\(credit.resolved)/\(settled(credit))"
    }

    static func outcomeColor(_ credit: FeatureTrajectories.Credit) -> Color {
        guard !sparse(credit), let rate = credit.rate else { return AryaColor.inkMuted }
        return rate >= 0.5 ? AryaColor.positive : AryaColor.negative
    }

    /// `9d` median lag, `<1d`, or `—`.
    static func lag(_ credit: FeatureTrajectories.Credit) -> String {
        guard let days = credit.medianLagDays else { return "—" }
        return days < 1 ? "<1d" : "\(Int(days.rounded()))d"
    }

    /// `high 0.71`, `medium 0.40`, `low 0.12`; sparse: `low confidence: 2 outcomes`.
    static func confidence(_ credit: FeatureTrajectories.Credit) -> String {
        let n = settled(credit)
        if sparse(credit) { return "low confidence: \(n) outcome\(n == 1 ? "" : "s")" }
        return "\(level(credit.confidence)) " + String(format: "%.2f", credit.confidence)
    }

    static func level(_ confidence: Double) -> String {
        confidence >= 0.66 ? "high" : confidence >= 0.33 ? "medium" : "low"
    }

    static func confidenceColor(_ credit: FeatureTrajectories.Credit) -> Color {
        switch level(credit.confidence) {
        case "high": AryaColor.positive
        case "medium": AryaColor.ink
        default: AryaColor.inkMuted
        }
    }
}

/// Resolved, reopened, and still-open outcomes as one proportional bar.
struct TrajectoryBar: View {
    var resolved: Int
    var reopened: Int
    var open: Int
    static let width: CGFloat = 240

    var body: some View {
        let total = CGFloat(max(1, resolved + reopened + open))
        HStack(spacing: 0) {
            segment(resolved, total, AryaColor.positive)
            segment(reopened, total, AryaColor.negative)
            segment(open, total, AryaColor.rule)
        }
        .frame(width: Self.width, height: AryaSpace.s1, alignment: .leading)
        .background(AryaColor.sunken)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func segment(_ count: Int, _ total: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(color).frame(width: Self.width * CGFloat(count) / total)
    }
}
