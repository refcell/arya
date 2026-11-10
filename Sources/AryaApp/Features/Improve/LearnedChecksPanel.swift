import AryaDesign
import SwiftUI

/// Learned checks on Improve: what people taught the steward by correcting and agreeing,
/// versioned, with the one-sentence score from the newest live rehearsal, then the checks
/// themselves, failing first. Dense rows: mark, case, the person's words, the origin chip.
struct LearnedChecksPanel: View {
    var checks: FeatureLearnedChecks
    /// Rows shown before "N more"; failing checks always lead.
    var limit = 8
    @AryaState private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text("CHECKS").aryaText(AryaFont.overline, AryaColor.inkFaint)
                Text("v\(checks.version)").aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                Text(LearnedChecksText.tally(checks))
                    .aryaText(AryaFont.monoSmall, LearnedChecksText.tallyColor(checks))
                    .monospacedDigit()
                Spacer(minLength: AryaSpace.s2)
                ProgressView(value: Double(checks.passed), total: Double(max(checks.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(AryaColor.positive)
                    .frame(width: 96)
                    .accessibilityLabel(checks.sentence)
            }
            Text(checks.sentence).aryaText(AryaFont.body, AryaColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            let shown = expanded ? checks.lines : Array(checks.lines.prefix(limit))
            ForEach(shown) { line in row(line) }
            if checks.lines.count > limit {
                Button(expanded ? "Fewer" : "\(checks.lines.count - limit) more") {
                    expanded.toggle()
                }
                .buttonStyle(.aryaTertiary)
            }
        }
    }

    private func row(_ line: FeatureLearnedChecks.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Group {
                if let passed = line.passed {
                    MarkGlyph(mark: passed ? .ok : .failed)
                } else {
                    MarkGlyph(mark: .idle)
                }
            }
            .frame(width: AryaSpace.s3)
            Text(line.caseID).aryaText(AryaFont.mono, AryaColor.ink)
                .frame(minWidth: 120, alignment: .leading)
            Text(line.text).aryaText(AryaFont.body, AryaColor.ink)
                .lineLimit(1).truncationMode(.tail)
            if line.passed == false {
                Text(line.found).aryaText(AryaFont.monoSmall, AryaColor.negative)
            }
            Spacer(minLength: AryaSpace.s2)
            Chip(line.origin)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.result)
        .help(line.result)
    }
}

/// Learned checks in words.
enum LearnedChecksText {
    /// `8/9 pass`, `3 not rehearsed`, or `none yet`.
    static func tally(_ checks: FeatureLearnedChecks) -> String {
        guard checks.total > 0 else { return "none yet" }
        guard checks.scored > 0 else { return "\(checks.total) not rehearsed" }
        return "\(checks.passed)/\(checks.total) pass"
    }

    static func tallyColor(_ checks: FeatureLearnedChecks) -> Color {
        guard checks.scored > 0 else { return AryaColor.inkMuted }
        return checks.passed == checks.scored ? AryaColor.positive : AryaColor.negative
    }
}
