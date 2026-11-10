import AryaDesign
import SwiftUI

/// An unboxed section: a small uppercase label with an optional trailing count, then content.
/// Structure comes from whitespace and type, never a fill or border.
struct OutcomeSection<Content: View>: View {
    let title: String
    let trailing: String?
    let content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        // Rows sit flush at the dense row height (24 pt pitch); only the title gets a gap.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).aryaText(AryaFont.overline, AryaColor.inkFaint)
                Spacer(minLength: AryaSpace.s2)
                if let trailing {
                    Text(trailing).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                }
            }
            .padding(.bottom, AryaSpace.s1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The outcome status as a plain uppercase colored label: the word always shows, color only
/// reinforces it.
struct OutcomeStatusPill: View {
    let status: OutcomeStatus

    var body: some View {
        Text(status.word)
            .aryaText(AryaFont.overline, color)
            .accessibilityLabel("Status: \(status.word)")
    }

    private var color: Color {
        switch status {
        case .onTrack: AryaColor.positive
        case .offTrack: AryaColor.negative
        case .atRisk, .recovering: AryaColor.ink
        case .noTarget, .noData, .paused: AryaColor.inkFaint
        }
    }
}

/// A small pill with a word, for risk and other short labels.
struct OutcomePill: View {
    let text: String
    var color: Color = AryaColor.inkMuted

    var body: some View {
        Text(text)
            .aryaText(AryaFont.monoSmall, color)
            .padding(.horizontal, AryaSpace.s2)
            .overlay(Capsule().strokeBorder(AryaColor.rule))
    }
}

/// A compact line of the metric's daily values, with the target as a dashed rule and the
/// latest value as a dot.
struct OutcomeSparkline: View {
    let values: [Double]
    let target: Double?
    var height: CGFloat = AryaSize.sparklineHeight

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.size
            let scale = Scale(values: values, target: target, bounds: frame)
            ZStack(alignment: .topLeading) {
                if let target {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: scale.y(target)))
                        path.addLine(to: CGPoint(x: frame.width, y: scale.y(target)))
                    }
                    .stroke(
                        AryaColor.inkFaint,
                        style: StrokeStyle(
                            lineWidth: 1, dash: [AryaSpace.s1, AryaSpace.s1]))
                }
                Path { path in
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(x: scale.x(index), y: scale.y(value))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(AryaColor.ink, lineWidth: AryaSize.chartLine)
                if let last = values.last {
                    Circle().fill(AryaColor.ink)
                        .frame(width: AryaSize.statusDot, height: AryaSize.statusDot)
                        .position(x: scale.x(values.count - 1), y: scale.y(last))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Maps values to points, padded so the line and dot never touch the edges.
    struct Scale {
        let low: Double
        let high: Double
        let count: Int
        let bounds: CGSize
        let inset = AryaSize.statusDot

        init(values: [Double], target: Double?, bounds: CGSize) {
            let all = values + (target.map { [$0] } ?? [])
            low = all.min() ?? 0
            high = all.max() ?? 1
            count = values.count
            self.bounds = bounds
        }

        func x(_ index: Int) -> CGFloat {
            guard count > 1 else { return bounds.width / 2 }
            return inset + (bounds.width - 2 * inset) * CGFloat(index) / CGFloat(count - 1)
        }

        func y(_ value: Double) -> CGFloat {
            let span = high - low
            let unit = span > 1e-12 ? (value - low) / span : 0.5
            return inset + (bounds.height - 2 * inset) * CGFloat(1 - unit)
        }
    }
}

/// An uppercase label over a monospaced value, for the headline's facts grid.
/// "Next run 14:00 · last 5 ✓✓✓✕✓": when the steward runs next and how its
/// last triggered runs went.
struct OutcomeSchedule: View {
    let state: OutcomeState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1 / 2) {
            Text("Schedule").aryaText(AryaFont.overline, AryaColor.inkFaint)
            HStack(spacing: AryaSpace.s1) {
                Text(state.wake.schedule(now: now, serving: state.serving))
                    .aryaText(AryaFont.monoSmall, AryaColor.ink)
                if !state.triggers.isEmpty {
                    Text("· last \(state.triggers.count)")
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                    TriggerStrip(state.triggers)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct OutcomeFact: View {
    let label: String
    let value: String
    var color: Color = AryaColor.ink

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1 / 2) {
            Text(label).aryaText(AryaFont.overline, AryaColor.inkFaint)
            Text(value).aryaText(AryaFont.monoSmall, color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
