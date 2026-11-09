import AppKit
import SwiftUI

/// The appearance a color token is resolved in.
public struct AryaScheme: Hashable, Sendable, CaseIterable {
    /// The dark scheme (the default) rather than light.
    public var isDark: Bool
    /// The system Increase Contrast setting.
    public var isHighContrast: Bool

    public init(isDark: Bool, isHighContrast: Bool = false) {
        self.isDark = isDark
        self.isHighContrast = isHighContrast
    }

    public static let light = AryaScheme(isDark: false)
    public static let dark = AryaScheme(isDark: true)
    public static let allCases: [AryaScheme] = [
        .dark, .light,
        AryaScheme(isDark: false, isHighContrast: true),
        AryaScheme(isDark: true, isHighContrast: true),
    ]

    /// The scheme matching an AppKit appearance.
    public init(_ appearance: NSAppearance) {
        let names: [NSAppearance.Name] = [
            .aqua, .darkAqua, .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua,
        ]
        let match = appearance.bestMatch(from: names) ?? .aqua
        self.init(
            isDark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
            isHighContrast: match == .accessibilityHighContrastAqua
                || match == .accessibilityHighContrastDarkAqua
        )
    }
}

/// Every color token in `docs/STYLE.md`, with its dark (default) and light values. One canvas
/// covers the window; `raised` is only for code, logs, and fields (decision 0036).
public enum AryaColorToken: String, CaseIterable, Sendable {
    case canvas, raised, selection
    case ink, inkMuted, inkFaint
    case rule, ruleStrong
    case accent, accentInk
    case positive, positiveWash, negative, negativeWash, warning

    /// The value in the dark scheme, the app's default.
    public var dark: AryaRGB {
        switch self {
        case .canvas: AryaRGB(0x0C0C0D)
        case .raised: AryaRGB(0x141416)
        case .selection: AryaRGB(0x1C1C1F)
        case .ink: AryaRGB(0xF4F4F5)
        case .inkMuted: AryaRGB(0xA1A1AA)
        case .inkFaint: AryaRGB(0x8B8B94)
        case .rule: AryaRGB(0x1F1F21)
        case .ruleStrong: AryaRGB(0x2C2C30)
        case .accent: AryaRGB(0xF97316)
        case .accentInk: AryaRGB(0x0C0C0D)
        case .positive: AryaRGB(0x4ADE80)
        case .positiveWash: AryaRGB(0x0E1F14)
        case .negative: AryaRGB(0xF87171)
        case .negativeWash: AryaRGB(0x251314)
        case .warning: AryaRGB(0xFBBF24)
        }
    }

    /// The value in the light scheme.
    public var light: AryaRGB {
        switch self {
        case .canvas: AryaRGB(0xFAFAFA)
        case .raised: AryaRGB(0xF2F2F3)
        case .selection: AryaRGB(0xE9E9EC)
        case .ink: AryaRGB(0x18181B)
        case .inkMuted: AryaRGB(0x52525B)
        case .inkFaint: AryaRGB(0x63636C)
        case .rule: AryaRGB(0xE4E4E7)
        case .ruleStrong: AryaRGB(0xD4D4D8)
        case .accent: AryaRGB(0xB4390A)
        case .accentInk: AryaRGB(0xFFFFFF)
        case .positive: AryaRGB(0x166534)
        case .positiveWash: AryaRGB(0xE9F9EE)
        case .negative: AryaRGB(0xB91C1C)
        case .negativeWash: AryaRGB(0xFDECEC)
        case .warning: AryaRGB(0x8A5405)
        }
    }

    /// The token this one stands in for under Increase Contrast (STYLE.md, Accessibility).
    public var highContrastSubstitute: AryaColorToken {
        switch self {
        case .rule, .ruleStrong: .inkFaint
        case .inkFaint: .inkMuted
        default: self
        }
    }

    /// The value in a scheme.
    public func value(in scheme: AryaScheme) -> AryaRGB {
        let token = scheme.isHighContrast ? highContrastSubstitute : self
        return scheme.isDark ? token.dark : token.light
    }

    /// A dynamic AppKit color that follows the effective appearance.
    public var nsColor: NSColor {
        NSColor(name: NSColor.Name("arya." + rawValue)) { appearance in
            let (red, green, blue) = value(in: AryaScheme(appearance)).components
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }

    /// A dynamic SwiftUI color that follows the effective appearance.
    public var color: Color { Color(nsColor: nsColor) }
}

/// Color tokens as SwiftUI colors. Feature views use these, never literal colors.
public enum AryaColor {
    public static let canvas = AryaColorToken.canvas.color
    public static let raised = AryaColorToken.raised.color
    public static let selection = AryaColorToken.selection.color
    public static let ink = AryaColorToken.ink.color
    public static let inkMuted = AryaColorToken.inkMuted.color
    public static let inkFaint = AryaColorToken.inkFaint.color
    public static let rule = AryaColorToken.rule.color
    public static let ruleStrong = AryaColorToken.ruleStrong.color
    public static let accent = AryaColorToken.accent.color
    public static let accentInk = AryaColorToken.accentInk.color
    public static let positive = AryaColorToken.positive.color
    public static let positiveWash = AryaColorToken.positiveWash.color
    public static let negative = AryaColorToken.negative.color
    public static let negativeWash = AryaColorToken.negativeWash.color
    public static let warning = AryaColorToken.warning.color

    /// Older names, kept so views compile while they move to one canvas. Panes are not filled,
    /// so `surface` is the canvas; code and fields use `raised`; tinted boxes are gone.
    public static let surface = canvas
    public static let sunken = raised
    public static let accentWash = canvas
    public static let warningWash = canvas
}

/// The app's appearance. Dark is the default whatever the system setting (STYLE.md, decision
/// 0036); light is a secondary choice.
public enum AryaAppearance: String, CaseIterable, Sendable {
    case dark, light

    /// The AppKit appearance to set on `NSApp.appearance`.
    public var nsAppearanceName: NSAppearance.Name {
        switch self {
        case .dark: .darkAqua
        case .light: .aqua
        }
    }

    /// A stored choice, falling back to dark for anything unknown.
    public init(stored: String?) {
        self = stored.flatMap(AryaAppearance.init(rawValue:)) ?? .dark
    }
}
