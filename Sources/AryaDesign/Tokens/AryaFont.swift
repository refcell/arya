import AppKit
import SwiftUI

/// A type token from `docs/STYLE.md`: face, size, line height, weight, tracking, and case.
public struct AryaTextStyle: Hashable, Sendable {
    /// The system face a style uses.
    public enum Face: String, Sendable, CaseIterable {
        case serif, sans, mono
    }

    public let name: String
    public let face: Face
    /// Point size at the standard text size.
    public let size: CGFloat
    /// Line height in points at the standard text size.
    public let lineHeight: CGFloat
    public let weight: Font.Weight
    /// Letter spacing in points.
    public let tracking: CGFloat
    public let uppercase: Bool

    public init(
        name: String, face: Face, size: CGFloat, lineHeight: CGFloat,
        weight: Font.Weight = .regular, tracking: CGFloat = 0, uppercase: Bool = false
    ) {
        self.name = name
        self.face = face
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.tracking = tracking
        self.uppercase = uppercase
    }

    /// The SwiftUI font at a text-size scale (1 is the standard size).
    public func font(scale: CGFloat = 1) -> Font {
        .system(size: size * scale, weight: weight, design: face.design)
    }

    /// The AppKit font at a text-size scale, used to measure the natural line height.
    public func nsFont(scale: CGFloat = 1) -> NSFont {
        let base = NSFont.systemFont(ofSize: size * scale, weight: weight.nsWeight)
        guard let descriptor = base.fontDescriptor.withDesign(face.nsDesign),
            let font = NSFont(descriptor: descriptor, size: size * scale)
        else { return base }
        return font
    }

    /// The font's own line height at a scale, as AppKit lays it out.
    public func naturalLineHeight(scale: CGFloat = 1) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: nsFont(scale: scale))
    }

    /// Extra spacing between lines so lines sit `lineHeight` apart: lineHeight − natural.
    public func lineSpacing(scale: CGFloat = 1) -> CGFloat {
        max(0, lineHeight * scale - naturalLineHeight(scale: scale))
    }
}

extension AryaTextStyle.Face {
    var design: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .mono: .monospaced
        }
    }

    var nsDesign: NSFontDescriptor.SystemDesign {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .mono: .monospaced
        }
    }
}

extension Font.Weight {
    var nsWeight: NSFont.Weight {
        switch self {
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
    }
}

/// The type scale from `docs/STYLE.md`.
public enum AryaFont {
    public static let display = AryaTextStyle(
        name: "display", face: .serif, size: 30, lineHeight: 36)
    public static let title = AryaTextStyle(
        name: "title", face: .serif, size: 22, lineHeight: 28)
    public static let heading = AryaTextStyle(
        name: "heading", face: .serif, size: 17, lineHeight: 22, weight: .semibold)
    public static let body = AryaTextStyle(
        name: "body", face: .sans, size: 13, lineHeight: 19)
    public static let bodyStrong = AryaTextStyle(
        name: "bodyStrong", face: .sans, size: 13, lineHeight: 19, weight: .semibold)
    public static let caption = AryaTextStyle(
        name: "caption", face: .sans, size: 11, lineHeight: 15)
    public static let overline = AryaTextStyle(
        name: "overline", face: .sans, size: 10, lineHeight: 14, weight: .medium,
        tracking: 0.8, uppercase: true)
    public static let mono = AryaTextStyle(
        name: "mono", face: .mono, size: 12, lineHeight: 18)
    public static let monoSmall = AryaTextStyle(
        name: "monoSmall", face: .mono, size: 11, lineHeight: 16)

    /// Every type token, in the guide's order.
    public static let all: [AryaTextStyle] = [
        display, title, heading, body, bodyStrong, caption, overline, mono, monoSmall,
    ]
}

private struct AryaTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// The app's text-size scale; every type token scales by it together. 1 is standard.
    /// (A plain key, not `@Entry`: the command-line tools ship no SwiftUI macro plugin.)
    public var aryaTextScale: CGFloat {
        get { self[AryaTextScaleKey.self] }
        set { self[AryaTextScaleKey.self] = newValue }
    }
}

/// Applies a type token's font, line spacing, tracking, and case together.
struct AryaTextModifier: ViewModifier {
    let style: AryaTextStyle
    @Environment(\.aryaTextScale) private var scale

    func body(content: Content) -> some View {
        content
            .font(style.font(scale: scale))
            .lineSpacing(style.lineSpacing(scale: scale))
            .tracking(style.tracking * scale)
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

extension View {
    /// Sets text in a type token: `Text("Stewards").aryaText(AryaFont.overline)`.
    public func aryaText(_ style: AryaTextStyle) -> some View {
        modifier(AryaTextModifier(style: style))
    }

    /// Sets text in a type token and a color token together.
    public func aryaText(_ style: AryaTextStyle, _ color: Color) -> some View {
        modifier(AryaTextModifier(style: style)).foregroundStyle(color)
    }
}
