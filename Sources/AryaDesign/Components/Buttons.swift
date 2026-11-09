import SwiftUI

/// The three button kinds from STYLE.md.
public enum AryaButtonKind: Sendable {
    case primary, secondary, tertiary
}

/// Shared body for the three button styles: 28 pt tall, small radius, 12 pt padding,
/// 70% opacity while pressed, and a 2 pt accent focus ring with a 2 pt offset.
struct AryaButtonBody: View {
    let kind: AryaButtonKind
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .aryaText(AryaFont.bodyStrong, textColor)
            .padding(.horizontal, AryaSpace.s3)
            .frame(height: AryaSize.controlHeight)
            .background(fill, in: shape)
            .overlay {
                if kind == .secondary { shape.strokeBorder(AryaColor.ruleStrong, lineWidth: 1) }
            }
            .padding(AryaSize.focusRing)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: AryaRadius.small + AryaSize.focusRing)
                        .strokeBorder(AryaColor.accent, lineWidth: AryaSize.focusRing)
                        .padding(-AryaSize.focusRing)
                }
            }
            .padding(-AryaSize.focusRing)
            .opacity(configuration.isPressed ? AryaSize.pressedOpacity : 1)
            .contentShape(shape)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AryaRadius.small) }

    private var textColor: Color {
        guard isEnabled else { return AryaColor.inkFaint }
        switch kind {
        case .primary: return AryaColor.accentInk
        case .secondary: return AryaColor.ink
        case .tertiary: return AryaColor.inkMuted
        }
    }

    private var fill: Color {
        guard kind == .primary else { return .clear }
        return isEnabled ? AryaColor.accent : .clear
    }
}

/// The one action that moves work forward. At most one per pane, rightmost.
public struct AryaPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        AryaButtonBody(kind: .primary, configuration: configuration)
    }
}

/// Alternatives: Deny, Cancel, Rehearse.
public struct AryaSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        AryaButtonBody(kind: .secondary, configuration: configuration)
    }
}

/// Low-stakes actions: Show more, Copy.
public struct AryaTertiaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        AryaButtonBody(kind: .tertiary, configuration: configuration)
    }
}

extension ButtonStyle where Self == AryaPrimaryButtonStyle {
    public static var aryaPrimary: AryaPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == AryaSecondaryButtonStyle {
    public static var aryaSecondary: AryaSecondaryButtonStyle { .init() }
}

extension ButtonStyle where Self == AryaSecondaryButtonStyle {
    /// The quiet button: no fill, a `ruleStrong` outline (STYLE.md Buttons).
    public static var aryaQuiet: AryaSecondaryButtonStyle { .init() }
}

extension ButtonStyle where Self == AryaTertiaryButtonStyle {
    public static var aryaTertiary: AryaTertiaryButtonStyle { .init() }
}
