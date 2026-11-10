import SwiftUI

/// The three button kinds from STYLE.md.
public enum AryaButtonKind: Sendable {
    case primary, secondary, tertiary
}

/// Shared body for the three button styles (STYLE.md Controls): 24 pt tall, small radius,
/// 8 pt padding, an optional faint keycap after the label, a `raised` fill on hover and a
/// `selection` fill while pressed. Primary is the orange fill; secondary and tertiary carry
/// a hairline border and differ only in ink. Focus draws a 2 pt accent ring.
struct AryaButtonBody: View {
    let kind: AryaButtonKind
    let keys: String?
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @AryaState private var isHovered = false

    var body: some View {
        HStack(spacing: AryaSpace.s2) {
            configuration.label.aryaText(AryaFont.bodyStrong, textColor)
            if let keys {
                Text(keys).aryaText(AryaFont.monoSmall, keyColor).accessibilityHidden(true)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, AryaSpace.s2)
        .frame(height: AryaSize.buttonHeight)
        .background(fill, in: shape)
        .overlay {
            if kind != .primary { shape.strokeBorder(border, lineWidth: 1) }
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: AryaRadius.small + AryaSize.focusRing)
                    .strokeBorder(AryaColor.accent, lineWidth: AryaSize.focusRing)
                    .padding(-AryaSize.focusRing)
            }
        }
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .animation(AryaMotion.quick, value: isHovered)
        .animation(AryaMotion.quick, value: configuration.isPressed)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AryaRadius.small) }

    private var textColor: Color {
        guard isEnabled else { return AryaColor.inkFaint }
        switch kind {
        case .primary: return AryaColor.accentInk
        case .secondary: return AryaColor.ink
        case .tertiary: return isHovered ? AryaColor.ink : AryaColor.inkMuted
        }
    }

    private var keyColor: Color {
        kind == .primary && isEnabled ? AryaColor.accentInk.opacity(0.7) : AryaColor.inkFaint
    }

    private var border: Color {
        guard isEnabled else { return AryaColor.rule }
        return kind == .secondary || isHovered ? AryaColor.ruleStrong : AryaColor.rule
    }

    private var fill: Color {
        if kind == .primary {
            guard isEnabled else { return AryaColor.raised }
            return configuration.isPressed ? AryaColor.accent : AryaColor.accentFill
        }
        guard isEnabled else { return .clear }
        if configuration.isPressed { return AryaColor.selection }
        return isHovered ? AryaColor.raised : .clear
    }
}

/// The one action that moves work forward. At most one per pane, rightmost.
public struct AryaPrimaryButtonStyle: ButtonStyle {
    let keys: String?
    public init(keys: String? = nil) { self.keys = keys }
    public func makeBody(configuration: Configuration) -> some View {
        AryaButtonBody(kind: .primary, keys: keys, configuration: configuration)
    }
}

/// Alternatives: Deny, Cancel, Rehearse.
public struct AryaSecondaryButtonStyle: ButtonStyle {
    let keys: String?
    public init(keys: String? = nil) { self.keys = keys }
    public func makeBody(configuration: Configuration) -> some View {
        AryaButtonBody(kind: .secondary, keys: keys, configuration: configuration)
    }
}

/// Low-stakes actions: Show more, Copy, Edit charter.
public struct AryaTertiaryButtonStyle: ButtonStyle {
    let keys: String?
    public init(keys: String? = nil) { self.keys = keys }
    public func makeBody(configuration: Configuration) -> some View {
        AryaButtonBody(kind: .tertiary, keys: keys, configuration: configuration)
    }
}

extension ButtonStyle where Self == AryaPrimaryButtonStyle {
    public static var aryaPrimary: AryaPrimaryButtonStyle { .init() }
    /// With a faint keycap after the label: `.aryaPrimary(keys: "⌘↩")`.
    public static func aryaPrimary(keys: String) -> AryaPrimaryButtonStyle { .init(keys: keys) }
}

extension ButtonStyle where Self == AryaSecondaryButtonStyle {
    public static var aryaSecondary: AryaSecondaryButtonStyle { .init() }
    /// With a faint keycap after the label: `.aryaSecondary(keys: "⌥⌘P")`.
    public static func aryaSecondary(keys: String) -> AryaSecondaryButtonStyle {
        .init(keys: keys)
    }
    /// The quiet button: the secondary look (STYLE.md Buttons).
    public static var aryaQuiet: AryaSecondaryButtonStyle { .init() }
    /// The quiet button with a keycap.
    public static func aryaQuiet(keys: String) -> AryaSecondaryButtonStyle { .init(keys: keys) }
}

extension ButtonStyle where Self == AryaTertiaryButtonStyle {
    public static var aryaTertiary: AryaTertiaryButtonStyle { .init() }
    /// With a faint keycap after the label.
    public static func aryaTertiary(keys: String) -> AryaTertiaryButtonStyle { .init(keys: keys) }
}

/// A 24 pt square button holding one SF Symbol: no border until hover, a `selection` fill
/// while pressed. Its help names the action and its shortcut.
public struct AryaIconButton: View {
    let symbol: String
    let label: String
    let keys: String?
    let action: () -> Void

    public init(
        _ symbol: String, label: String, keys: String? = nil, action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.keys = keys
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(AryaIconButtonStyle())
        .help(keys.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

/// The icon button's look, usable on any `Button` whose label is an `Image`.
public struct AryaIconButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        AryaIconBody(configuration: configuration)
    }
}

struct AryaIconBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @AryaState private var isHovered = false

    var body: some View {
        configuration.label
            .font(AryaFont.caption.font())
            .foregroundStyle(color)
            .frame(width: AryaSize.buttonHeight, height: AryaSize.buttonHeight)
            .background(fill, in: shape)
            .overlay { if isHovered { shape.strokeBorder(AryaColor.rule, lineWidth: 1) } }
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(AryaMotion.quick, value: isHovered)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: AryaRadius.small) }

    private var color: Color {
        guard isEnabled else { return AryaColor.inkFaint }
        return isHovered ? AryaColor.ink : AryaColor.inkMuted
    }

    private var fill: Color {
        if configuration.isPressed { return AryaColor.selection }
        return isHovered ? AryaColor.raised : .clear
    }
}

/// A row of controls above a pane's content: 32 pt tall, 8 pt gaps, hairline below. Put the
/// primary action last.
public struct AryaToolbar<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        HStack(spacing: AryaSpace.s2) { content }
            .frame(height: AryaSize.toolbarHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { AryaHairline() }
    }
}

extension View {
    /// A pull-down `Menu` drawn as a secondary button: 24 pt, a `ruleStrong` hairline, label
    /// in `bodyStrong` `ink`, the system chevron kept as the menu's tell.
    public func aryaMenuButton() -> some View {
        self.menuStyle(.borderlessButton)
            .aryaText(AryaFont.bodyStrong, AryaColor.ink)
            .padding(.horizontal, AryaSpace.s2)
            .frame(height: AryaSize.buttonHeight)
            .overlay {
                RoundedRectangle(cornerRadius: AryaRadius.small)
                    .strokeBorder(AryaColor.ruleStrong, lineWidth: 1)
            }
    }
}
