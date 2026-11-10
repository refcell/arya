import SwiftUI

/// A 6 pt status dot. A live dot pulses between 100% and 40% unless Reduce Motion is on.
public struct StatusDot: View {
    let status: AryaStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AryaState private var dimmed = false

    public init(_ status: AryaStatus) {
        self.status = status
    }

    public var body: some View {
        Circle()
            .fill(status.isHollow ? Color.clear : status.dotToken.color)
            .overlay {
                if status.isHollow { Circle().strokeBorder(status.dotToken.color, lineWidth: 1) }
            }
            .frame(width: AryaSize.statusDot, height: AryaSize.statusDot)
            .opacity(dimmed ? AryaMotion.pulseMinOpacity : 1)
            .onAppear {
                guard status.isLive, let pulse = AryaMotion.pulse(reduceMotion: reduceMotion)
                else { return }
                withAnimation(pulse) { dimmed = true }
            }
            .accessibilityHidden(true)
    }
}

/// How the last few triggered runs went, oldest first: "✓✓✓✕✓", a check in the
/// positive tone per run that finished and a cross in the negative tone per run that failed.
public struct TriggerStrip: View {
    let outcomes: [Bool]

    public init(_ outcomes: [Bool]) {
        self.outcomes = outcomes
    }

    public var body: some View {
        outcomes.reduce(Text("")) { line, ok in
            line
                + Text(ok ? "✓" : "✕")
                .foregroundColor(ok ? AryaColor.positive : AryaColor.negative)
        }
        .aryaText(AryaFont.monoSmall)
        .accessibilityLabel(
            "\(outcomes.filter { $0 }.count) of the last \(outcomes.count) runs succeeded")
    }
}

/// A dot paired with its word: the way every run and approval state is shown.
public struct StatusBadge: View {
    let status: AryaStatus

    public init(_ status: AryaStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: AryaSpace.s1) {
            StatusDot(status)
            Text(status.word).aryaText(AryaFont.caption, textColor)
        }
        .accessibilityElement(children: .combine)
    }

    private var textColor: Color {
        switch status {
        case .failed, .denied: AryaColor.negative
        default: AryaColor.inkMuted
        }
    }
}

/// A caption-sized word or short id in a 1 px bordered box. Never a button.
public struct Chip: View {
    let text: String
    let textColor: Color
    let borderColor: Color

    public init(
        _ text: String, textColor: Color = AryaColor.inkMuted, borderColor: Color = AryaColor.rule
    ) {
        self.text = text
        self.textColor = textColor
        self.borderColor = borderColor
    }

    public var body: some View {
        Text(text)
            .aryaText(AryaFont.caption, textColor)
            .padding(.vertical, AryaSpace.s1)
            .padding(.horizontal, AryaSpace.s2)
            .overlay {
                RoundedRectangle(cornerRadius: AryaRadius.small)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
    }
}

/// The policy chip on a proposed action: the word always shows, color is a second cue.
public struct PolicyChip: View {
    let policy: AryaPolicy

    public init(_ policy: AryaPolicy) {
        self.policy = policy
    }

    public var body: some View {
        Chip(
            policy.rawValue, textColor: policy.textToken.color,
            borderColor: policy.borderToken.color
        )
        .accessibilityLabel("Policy \(policy.rawValue)")
    }
}

/// A count after a label, in `caption`/`inkFaint`; hidden entirely at zero.
public struct CountLabel: View {
    let count: Int
    let style: AryaTextStyle
    let color: Color

    public init(
        _ count: Int, style: AryaTextStyle = AryaFont.caption, color: Color = AryaColor.inkFaint
    ) {
        self.count = count
        self.style = style
        self.color = color
    }

    /// The text shown for a count, or nil when nothing should show.
    public static func text(for count: Int) -> String? { count > 0 ? "\(count)" : nil }

    public var body: some View {
        if let text = Self.text(for: count) {
            Text(text).aryaText(style, color).monospacedDigit()
        }
    }
}
