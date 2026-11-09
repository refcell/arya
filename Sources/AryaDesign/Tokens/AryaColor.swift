import AppKit
import SwiftUI

/// The appearance a color token is resolved in.
public struct AryaScheme: Hashable, Sendable, CaseIterable {
    /// Dark (ink) rather than light (paper).
    public var isDark: Bool
    /// The system Increase Contrast setting.
    public var isHighContrast: Bool

    public init(isDark: Bool, isHighContrast: Bool = false) {
        self.isDark = isDark
        self.isHighContrast = isHighContrast
    }

    public static let paper = AryaScheme(isDark: false)
    public static let ink = AryaScheme(isDark: true)
    public static let allCases: [AryaScheme] = [
        .paper, .ink,
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

/// Every color token in `docs/STYLE.md`, with its paper and ink values.
public enum AryaColorToken: String, CaseIterable, Sendable {
    case canvas, surface, sunken, selection
    case ink, inkMuted, inkFaint
    case rule, ruleStrong
    case accent, accentInk, accentWash
    case positive, negative

    /// The value in the light (paper) scheme.
    public var light: AryaRGB {
        switch self {
        case .canvas: AryaRGB(0xF6F1E7)
        case .surface: AryaRGB(0xFBF8F2)
        case .sunken: AryaRGB(0xEFE8DA)
        case .selection: AryaRGB(0xECE5D7)
        case .ink: AryaRGB(0x1D1B17)
        case .inkMuted: AryaRGB(0x4F4A3E)
        case .inkFaint: AryaRGB(0x6B6557)
        case .rule: AryaRGB(0xDDD4C2)
        case .ruleStrong: AryaRGB(0xC7BCA6)
        case .accent: AryaRGB(0xB13B0B)
        case .accentInk: AryaRGB(0xFFFFFF)
        case .accentWash: AryaRGB(0xF6E3D3)
        case .positive: AryaRGB(0x3F6B3A)
        case .negative: AryaRGB(0x9B2C2C)
        }
    }

    /// The value in the dark (ink) scheme.
    public var dark: AryaRGB {
        switch self {
        case .canvas: AryaRGB(0x141311)
        case .surface: AryaRGB(0x1B1A17)
        case .sunken: AryaRGB(0x100F0D)
        case .selection: AryaRGB(0x25231F)
        case .ink: AryaRGB(0xECE6DA)
        case .inkMuted: AryaRGB(0xB5AE9F)
        case .inkFaint: AryaRGB(0x918B7F)
        case .rule: AryaRGB(0x2B2925)
        case .ruleStrong: AryaRGB(0x3A3731)
        case .accent: AryaRGB(0xF08A4B)
        case .accentInk: AryaRGB(0x1A0F08)
        case .accentWash: AryaRGB(0x2E1D13)
        case .positive: AryaRGB(0x8DBF7F)
        case .negative: AryaRGB(0xE58A80)
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
    public static let surface = AryaColorToken.surface.color
    public static let sunken = AryaColorToken.sunken.color
    public static let selection = AryaColorToken.selection.color
    public static let ink = AryaColorToken.ink.color
    public static let inkMuted = AryaColorToken.inkMuted.color
    public static let inkFaint = AryaColorToken.inkFaint.color
    public static let rule = AryaColorToken.rule.color
    public static let ruleStrong = AryaColorToken.ruleStrong.color
    public static let accent = AryaColorToken.accent.color
    public static let accentInk = AryaColorToken.accentInk.color
    public static let accentWash = AryaColorToken.accentWash.color
    public static let positive = AryaColorToken.positive.color
    public static let negative = AryaColorToken.negative.color
}
