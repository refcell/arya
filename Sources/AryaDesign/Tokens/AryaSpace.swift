import AppKit
import SwiftUI

/// The spacing scale in `docs/STYLE.md`, on a 4 pt grid.
public enum AryaSpace {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let s7: CGFloat = 32

    public static let all: [CGFloat] = [s1, s2, s3, s4, s5, s6, s7]
}

/// Fixed sizes in `docs/STYLE.md`.
public enum AryaSize {
    public static let sidebarWidth: CGFloat = 232
    public static let sidebarMinWidth: CGFloat = 200
    public static let sidebarMaxWidth: CGFloat = 320
    public static let inspectorWidth: CGFloat = 340
    /// The bottom status bar.
    public static let statusBarHeight: CGFloat = 22
    /// The command palette.
    public static let paletteWidth: CGFloat = 560
    /// Sidebar rows, threads, steps, and table rows.
    public static let rowHeight: CGFloat = 24
    public static let controlHeight: CGFloat = 24
    /// Buttons, icon buttons, and segmented controls.
    public static let buttonHeight: CGFloat = 24
    /// A toolbar row of controls.
    public static let toolbarHeight: CGFloat = 32
    /// A progress bar's track.
    public static let progressHeight: CGFloat = 3
    public static let tabBarHeight: CGFloat = 32
    public static let tabUnderline: CGFloat = 2
    /// Stream and inspector content starts this far from the window top: the title bar is
    /// hidden and the traffic lights sit over the sidebar, so headers use that band.
    public static let titleBarInset: CGFloat = 12
    /// The sidebar's top inset: clears the window's traffic lights.
    public static let trafficLightInset: CGFloat = 40
    public static let pagePadding: CGFloat = 24
    public static let readingWidth: CGFloat = 680
    public static let threadIndent: CGFloat = 18
    public static let stepGutter: CGFloat = 40
    public static let focusRing: CGFloat = 2
    public static let statusDot: CGFloat = 6
    public static let sparklineWidth: CGFloat = 80
    public static let sparklineHeight: CGFloat = 20
    public static let chartHeight: CGFloat = 120
    public static let chartLine: CGFloat = 1.5
    public static let windowMinWidth: CGFloat = 960
    public static let windowMinHeight: CGFloat = 600
    public static let pressedOpacity: Double = 0.7

    /// Older names kept while the feature views move over.
    public static let railWidth = sidebarWidth
    public static let railMinWidth = sidebarMinWidth
    public static let railMaxWidth = sidebarMaxWidth
    public static let railRowHeight = rowHeight
    public static let tableRowHeight = rowHeight
}

/// Corner radii: 4 pt for buttons, fields, and code. Pills use `Capsule`; there are no cards.
public enum AryaRadius {
    public static let small: CGFloat = 4
    /// Older name; the same 4 pt.
    public static let medium: CGFloat = 4
}

/// A 1 px rule in `rule` at every display scale (`1 / displayScale` pt).
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

    /// Hover and press feedback: 80 ms ease-out.
    public static let quick = Animation.easeOut(duration: 0.08)
    /// The inspector and palette sliding in and out: 180 ms.
    public static let panel = Animation.easeOut(duration: 0.18)
    /// How long a new row stays highlighted after it arrives.
    public static let arrivalSeconds = 1.2
    /// One spinner turn.
    public static let spinSeconds = 0.9

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
