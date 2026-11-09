import AryaDesign
import SwiftUI

// Interim components named after docs/STYLE.md. They move to AryaDesign (or are replaced by
// its versions) once the app-shell lane lands components.

/// A 6 pt status dot. Always shown next to a word, never alone.
struct FeatureDot: View {
    var color: Color

    var body: some View {
        Circle().fill(color).frame(width: AryaSize.statusDot, height: AryaSize.statusDot)
    }
}

/// A one-word label with a hairline border and no fill. Never a button.
struct FeatureChip: View {
    var text: String
    var textColor: Color = AryaColor.inkMuted
    var borderColor: Color = AryaColor.rule

    var body: some View {
        Text(text)
            .aryaText(AryaFont.caption)
            .foregroundStyle(textColor)
            .padding(.vertical, AryaSpace.s1)
            .padding(.horizontal, AryaSpace.s2)
            .overlay(
                RoundedRectangle(cornerRadius: AryaRadius.small)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
    }
}

/// The policy chip: `auto`, `ask`, or `deny`, with color as a second cue.
struct PolicyChip: View {
    var policy: String

    var body: some View {
        switch policy {
        case "auto": FeatureChip(text: policy, textColor: AryaColor.positive)
        case "deny": FeatureChip(text: policy, textColor: AryaColor.negative)
        case "ask":
            FeatureChip(text: policy, textColor: AryaColor.accent, borderColor: AryaColor.accent)
        default: FeatureChip(text: policy)
        }
    }
}

/// A monochrome code block that scrolls horizontally and never wraps.
struct FeatureCodeBlock: View {
    var text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .aryaText(AryaFont.mono)
                .foregroundStyle(AryaColor.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(AryaSpace.s3)
        }
        .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.medium))
    }
}

/// The empty state: one display sentence, one guidance line, at most one secondary action.
struct FeatureEmptyState: View {
    var title: String
    var guidance: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: AryaSpace.s3) {
            Text(title).aryaText(AryaFont.display).foregroundStyle(AryaColor.ink)
            Text(guidance).aryaText(AryaFont.body).foregroundStyle(AryaColor.inkMuted)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(FeatureSecondaryButtonStyle())
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: AryaSize.readingWidth)
        .padding(.top, AryaSpace.s7)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// The primary button: accent fill, the one action that moves work forward.
struct FeaturePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .aryaText(AryaFont.bodyStrong)
            .foregroundStyle(isEnabled ? AryaColor.accentInk : AryaColor.inkFaint)
            .padding(.horizontal, AryaSpace.s3)
            .frame(height: AryaSize.controlHeight)
            .background(
                isEnabled ? AryaColor.accent : AryaColor.rule,
                in: RoundedRectangle(cornerRadius: AryaRadius.small)
            )
            .opacity(configuration.isPressed ? AryaSize.pressedOpacity : 1)
    }
}

/// The secondary button: no fill, a `ruleStrong` border.
struct FeatureSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .aryaText(AryaFont.bodyStrong)
            .foregroundStyle(isEnabled ? AryaColor.ink : AryaColor.inkFaint)
            .padding(.horizontal, AryaSpace.s3)
            .frame(height: AryaSize.controlHeight)
            .overlay(
                RoundedRectangle(cornerRadius: AryaRadius.small)
                    .strokeBorder(AryaColor.ruleStrong, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? AryaSize.pressedOpacity : 1)
    }
}

/// The tertiary button: text only, for low-stakes actions.
struct FeatureTertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .aryaText(AryaFont.bodyStrong)
            .foregroundStyle(AryaColor.inkMuted)
            .opacity(configuration.isPressed ? AryaSize.pressedOpacity : 1)
    }
}
