import AppKit
import SwiftUI

/// The 4 pt spacing scale from `docs/STYLE.md`.
public enum AryaSpace {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 24
    public static let s6: CGFloat = 32
    public static let s7: CGFloat = 48

    /// Every step, smallest first.
    public static let all: [CGFloat] = [s1, s2, s3, s4, s5, s6, s7]
}

/// Fixed sizes from `docs/STYLE.md` (Layout and Components).
public enum AryaSize {
    public static let railWidth: CGFloat = 240
    public static let railMinWidth: CGFloat = 200
    public static let railMaxWidth: CGFloat = 320
    public static let railRowHeight: CGFloat = 28
    public static let tableRowHeight: CGFloat = 32
    public static let controlHeight: CGFloat = 28
    public static let tabBarHeight: CGFloat = 36
    public static let tabUnderline: CGFloat = 2
    public static let approvalEdge: CGFloat = 2
    public static let focusRing: CGFloat = 2
    public static let statusDot: CGFloat = 6
    public static let stepGutter: CGFloat = 32
    public static let readingWidth: CGFloat = 720
    public static let windowMinWidth: CGFloat = 960
    public static let windowMinHeight: CGFloat = 600
    public static let chartHeight: CGFloat = 160
    public static let sparklineHeight: CGFloat = 48
    public static let chartLine: CGFloat = 1.5
    /// The pressed-button opacity, the one sanctioned use of opacity.
    public static let pressedOpacity: Double = 0.7
}

/// Corner radii from `docs/STYLE.md`. No other radii exist.
public enum AryaRadius {
    public static let small: CGFloat = 4
    public static let medium: CGFloat = 6
}

/// A one-device-pixel line in `rule` (or `ruleStrong`), the only region separator.
public struct AryaHairline: View {
    /// The direction the line runs.
    public enum Axis: Sendable { case horizontal, vertical }

    let axis: Axis
    let color: Color
    @Environment(\.displayScale) private var displayScale

    public init(_ axis: Axis = .horizontal, color: Color = AryaColor.rule) {
        self.axis = axis
        self.color = color
    }

    /// Thickness in points for a display scale: exactly one device pixel.
    nonisolated public static func thickness(displayScale: CGFloat) -> CGFloat {
        1 / max(displayScale, 1)
    }

    public var body: some View {
        let thickness = Self.thickness(displayScale: displayScale)
        Rectangle()
            .fill(color)
            .frame(
                width: axis == .vertical ? thickness : nil,
                height: axis == .horizontal ? thickness : nil
            )
            .accessibilityHidden(true)
    }
}

extension View {
    /// Draws a hairline along one edge, edge to edge of the view.
    public func aryaHairline(edge: Edge, color: Color = AryaColor.rule) -> some View {
        overlay(alignment: edge.alignment) {
            AryaHairline(edge.isHorizontal ? .vertical : .horizontal, color: color)
        }
    }
}

extension Edge {
    fileprivate var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    fileprivate var isHorizontal: Bool { self == .leading || self == .trailing }
}

/// Motion from `docs/STYLE.md`: animations only explain change, and none under Reduce Motion.
public enum AryaMotion {
    /// New stream steps fade in: 120 ms ease-out.
    public static let appearSeconds = 0.12
    /// Expanding and collapsing: 160 ms ease-in-out.
    public static let expandSeconds = 0.16
    /// One full live-dot pulse cycle.
    public static let pulseSeconds = 1.6
    /// The live dot's lowest opacity.
    public static let pulseMinOpacity = 0.4

    public static func appear(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: appearSeconds)
    }

    public static func expand(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: expandSeconds)
    }

    public static func pulse(reduceMotion: Bool) -> Animation? {
        reduceMotion
            ? nil : .easeInOut(duration: pulseSeconds / 2).repeatForever(autoreverses: true)
    }
}
