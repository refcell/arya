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
            // The sentence carries the counts; the header does not repeat them.
            Text("WHAT WORKED").aryaText(AryaFont.overline, AryaColor.inkFaint)
            Text(trajectories.sentence).aryaText(AryaFont.body, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            // Kinds then choices, split evenly over two columns when the panel is wide, else one
            // column.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AryaSpace.s5) {
                    column(halves.first).frame(
                        minWidth: AryaSize.whatWorkedColumn,
                        idealWidth: AryaSize.whatWorkedColumn, maxWidth: .infinity)
                    column(halves.second).frame(
                        minWidth: AryaSize.whatWorkedColumn,
                        idealWidth: AryaSize.whatWorkedColumn, maxWidth: .infinity)
                }
                column(lines)
            }
            if hidden > 0 || expanded {
                Button(expanded ? "Fewer" : "\(hidden) more") { expanded.toggle() }
                    .buttonStyle(.aryaTertiary)
            }
        }
    }

    private var hidden: Int {
        ["kind", "choice"].reduce(0) { total, axis in
            total + max(0, trajectories.credits.filter { $0.axis == axis }.count - limit)
        }
    }

    /// One line of the table: a group's header or a credit row.
    private enum Line: Identifiable {
        case header(String)
        case credit(FeatureTrajectories.Credit)

        var id: String {
            switch self {
            case .header(let title): "header:\(title)"
            case .credit(let credit): "credit:\(credit.id)"
            }
        }
    }

    private var lines: [Line] {
        [("KINDS", "kind"), ("CHOICES", "choice")].flatMap { title, axis -> [Line] in
            let credits = trajectories.credits.filter { $0.axis == axis }
            guard !credits.isEmpty else { return [] }
            let shown = expanded ? credits : Array(credits.prefix(limit))
            return [.header(title)] + shown.map(Line.credit)
        }
    }

    /// The lines cut in two at the middle; a header never ends a column, and a group that
    /// carries on into the second column repeats its header there.
    private var halves: (first: [Line], second: [Line]) {
        var cut = (lines.count + 1) / 2
        if cut > 0, cut < lines.count, case .header = lines[cut - 1] { cut -= 1 }
        let first = Array(lines.prefix(cut))
        var second = Array(lines.dropFirst(cut))
        if case .credit = second.first,
            let open = first.last(where: { if case .header = $0 { true } else { false } })
        {
            second.insert(open, at: 0)
        }
        return (first, second)
    }

    private func column(_ lines: [Line]) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            ForEach(lines) { line in
                switch line {
                case .header(let title): header(title)
                case .credit(let credit): row(credit)
                }
            }
        }
    }

    /// The group name over the names, then the column labels over their columns.
    private func header(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(title).aryaText(AryaFont.overline, AryaColor.inkFaint)
                .frame(minWidth: 56, maxWidth: 140, alignment: .leading)
            Text("RESOLVED").aryaText(AryaFont.overline, AryaColor.inkFaint)
                .frame(minWidth: 52, alignment: .trailing)
            Text("LAG").aryaText(AryaFont.overline, AryaColor.inkFaint)
                .frame(minWidth: 28, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.top, AryaSpace.s1)
    }

    private func row(_ credit: FeatureTrajectories.Credit) -> some View {
        // A dense table row that fits a half-width column: the name gives way first, the bar
        // takes what is left.
        HStack(alignment: .center, spacing: AryaSpace.s2) {
            Text(credit.name).aryaText(AryaFont.mono, AryaColor.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 56, maxWidth: 140, alignment: .leading)
            Text(WhatWorkedText.outcome(credit))
                .aryaText(AryaFont.monoSmall, WhatWorkedText.outcomeColor(credit))
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
            Text(WhatWorkedText.lag(credit)).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                .monospacedDigit()
                .frame(minWidth: 28, alignment: .trailing)
            if WhatWorkedText.sparse(credit) {
                // Plain words, no chip or bar: too few outcomes to grade, and it fits a half
                // column.
                Text(WhatWorkedText.confidence(credit))
                    .aryaText(AryaFont.caption, AryaColor.inkFaint)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            } else {
                Chip(
                    WhatWorkedText.confidence(credit),
                    textColor: WhatWorkedText.confidenceColor(credit)
                )
                .fixedSize()
                // One chip column, so every bar starts at the same x.
                .frame(minWidth: 88, alignment: .leading)
                TrajectoryBar(rate: credit.rate ?? 0)
            }
        }
        .frame(minHeight: AryaSize.rowHeight)
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

/// The success rate (resolved of settled) as a bar: 21/21 and 63/63 both fill the row; the
/// counts stay in the text beside it.
struct TrajectoryBar: View {
    var rate: Double

    var body: some View {
        GeometryReader { box in
            Rectangle()
                .fill(rate >= 0.5 ? AryaColor.positive : AryaColor.negative)
                .frame(width: box.size.width * CGFloat(min(max(rate, 0), 1)))
        }
        .frame(minWidth: AryaSize.rowHeight * 2, maxWidth: .infinity)
        .frame(height: AryaSpace.s1)
        .background(AryaColor.sunken)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

extension AryaSize {
    /// One What worked group's narrowest column when kinds and choices sit side by side.
    static let whatWorkedColumn: CGFloat = 480
}
