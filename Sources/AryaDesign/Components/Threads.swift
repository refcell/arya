import Foundation
import SwiftUI

/// A run under its steward in the sidebar (STYLE.md Thread row): its summary in the sans caption
/// face, up to two lines, and a relative time. A run waiting on a person shows an accent dot.
public struct ThreadRow: View {
    let title: String
    let time: String
    let needsYou: Bool
    let isSelected: Bool

    public init(_ title: String, time: String, needsYou: Bool = false, isSelected: Bool = false) {
        self.title = title
        self.time = time
        self.needsYou = needsYou
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Circle()
                .fill(needsYou ? AryaColor.accentFill : .clear)
                .frame(width: AryaSize.statusDot, height: AryaSize.statusDot)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(title)
                .aryaText(AryaFont.caption, isSelected ? AryaColor.ink : AryaColor.inkMuted)
                .lineLimit(isSelected ? 2 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(time).aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
        }
        .padding(.leading, AryaSize.threadIndent - AryaSize.statusDot)
        .padding(.trailing, AryaSpace.s2)
        .padding(.vertical, AryaSpace.s1)
        .frame(minHeight: AryaSize.rowHeight)
        .background(
            isSelected ? AryaColor.selection : .clear,
            in: RoundedRectangle(cornerRadius: AryaRadius.small)
        )
        .contentShape(Rectangle())
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Run, \(title), \(time)\(needsYou ? ", needs you" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A compact time for thread rows (`AryaTime.label(_:now:style: .short)`).
    public static func shortTime(_ date: Date, now: Date) -> String {
        AryaTime.label(date, now: now, style: .short)
    }
}

/// A small inline line chart (STYLE.md Outcome line): no axes, the last point as a dot.
public struct Sparkline: View {
    let values: [Double]
    let onTarget: Bool

    public init(_ values: [Double], onTarget: Bool = true) {
        self.values = values
        self.onTarget = onTarget
    }

    /// Points scaled into a rect, oldest first. A flat or single series sits mid-height.
    nonisolated public static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard let low = values.min(), let high = values.max() else { return [] }
        let span = high - low
        let step = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let y = span == 0 ? 0.5 : 1 - (value - low) / span
            return CGPoint(
                x: values.count > 1 ? CGFloat(index) * step : size.width,
                y: CGFloat(y) * size.height)
        }
    }

    public var body: some View {
        Canvas { context, size in
            let inset = AryaSize.statusDot / 2
            let area = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
            let points = Self.points(values, in: area).map {
                CGPoint(x: $0.x + inset, y: $0.y + inset)
            }
            guard let last = points.last else { return }
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(AryaColor.inkMuted), lineWidth: AryaSize.chartLine)
            let dot = CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)
            context.fill(
                Path(ellipseIn: dot),
                with: .color(onTarget ? AryaColor.positive : AryaColor.warning))
        }
        .frame(width: AryaSize.sparklineWidth, height: AryaSize.sparklineHeight)
        .accessibilityHidden(true)
    }
}

/// An error shown on the action that failed (STYLE.md Errors), dismissible.
public struct InlineError: View {
    let message: String
    let dismiss: () -> Void

    public init(_ message: String, dismiss: @escaping () -> Void) {
        self.message = message
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(message).aryaText(AryaFont.caption, AryaColor.negative)
                .fixedSize(horizontal: false, vertical: true)
            Button("Dismiss", action: dismiss).buttonStyle(.aryaTertiary)
        }
    }
}
