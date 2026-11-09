import Foundation

/// An opaque sRGB color stored as its 24-bit hex value, as written in `docs/STYLE.md`.
public struct AryaRGB: Hashable, Sendable, CustomStringConvertible {
    /// The color as `0xRRGGBB`.
    public let hex: UInt32

    public init(_ hex: UInt32) {
        self.hex = hex & 0xFF_FFFF
    }

    /// Red, green, and blue channels in `0...1`.
    public var components: (red: Double, green: Double, blue: Double) {
        (
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255
        )
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.040_45 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let (red, green, blue) = components
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.x contrast ratio between two colors, from 1 to 21.
    public func contrast(with other: AryaRGB) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// `#RRGGBB`.
    public var description: String {
        let digits = String(hex, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - digits.count) + digits
    }
}
