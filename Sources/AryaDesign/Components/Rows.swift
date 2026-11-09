import SwiftUI

/// A 28 pt rail row: optional status dot, a label in `body`, an optional trailing caption,
/// and the `selection` fill when selected. `indent` nests rows (runs under a steward).
public struct RailRow: View {
    let title: String
    let status: AryaStatus?
    let trailing: String?
    let isSelected: Bool
    let indent: CGFloat

    public init(
        _ title: String, status: AryaStatus? = nil, trailing: String? = nil,
        isSelected: Bool = false, indent: CGFloat = 0
    ) {
        self.title = title
        self.status = status
        self.trailing = trailing
        self.isSelected = isSelected
        self.indent = indent
    }

    public var body: some View {
        HStack(spacing: AryaSpace.s2) {
            if let status { StatusDot(status) }
            Text(title).aryaText(AryaFont.body, AryaColor.ink).lineLimit(1)
            Spacer(minLength: AryaSpace.s2)
            if let trailing {
                Text(trailing).aryaText(AryaFont.caption, AryaColor.inkFaint).lineLimit(1)
            }
        }
        .padding(.leading, AryaSpace.s2 + indent)
        .padding(.trailing, AryaSpace.s2)
        .frame(height: AryaSize.rowHeight)
        .background(
            isSelected ? AryaColor.selection : .clear,
            in: RoundedRectangle(cornerRadius: AryaRadius.small)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(status?.word ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A rail group label in `overline`/`inkFaint`, with an optional accented trailing count.
public struct RailGroupLabel: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .aryaText(AryaFont.label, AryaColor.inkFaint)
            .padding(.horizontal, AryaSpace.s3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One event in a run: a 32 pt gutter with the sequence number, the title, a relative time,
/// and an optional body. A running step shows the live dot and the word `running`.
public struct StepRow<Title: View, Detail: View>: View {
    let sequence: Int
    let time: String?
    let absoluteTime: String?
    let isRunning: Bool
    let title: Title
    let detail: Detail

    public init(
        sequence: Int, time: String? = nil, absoluteTime: String? = nil, isRunning: Bool = false,
        @ViewBuilder title: () -> Title, @ViewBuilder detail: () -> Detail
    ) {
        self.sequence = sequence
        self.time = time
        self.absoluteTime = absoluteTime
        self.isRunning = isRunning
        self.title = title()
        self.detail = detail()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(AryaTime.sequence(sequence))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                .frame(width: AryaSize.stepGutter, alignment: .leading)
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    if isRunning { StatusDot(.running) }
                    title
                    if isRunning { Text("running").aryaText(AryaFont.caption, AryaColor.inkMuted) }
                    Spacer(minLength: AryaSpace.s2)
                    if let time {
                        Text(time).aryaText(AryaFont.caption, AryaColor.inkFaint)
                            .help(absoluteTime ?? time)
                    }
                }
                detail
            }
        }
    }
}

extension StepRow where Detail == EmptyView {
    public init(
        sequence: Int, time: String? = nil, absoluteTime: String? = nil, isRunning: Bool = false,
        @ViewBuilder title: () -> Title
    ) {
        self.init(
            sequence: sequence, time: time, absoluteTime: absoluteTime, isRunning: isRunning,
            title: title, detail: { EmptyView() })
    }
}

/// A 32 pt table row with `rule` hairline beneath and `selection` fill when selected.
public struct TableRowFrame<Content: View>: View {
    let isSelected: Bool
    let content: Content

    public init(isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.isSelected = isSelected
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, AryaSpace.s3)
            .frame(minHeight: AryaSize.tableRowHeight)
            .background(isSelected ? AryaColor.selection : .clear)
            .aryaHairline(edge: .bottom)
    }
}
