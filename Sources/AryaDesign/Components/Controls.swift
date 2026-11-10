import SwiftUI

/// The effort selector: `Effort` in `caption`/`inkMuted` and three segments, 28 pt tall.
/// The selected segment is an `ink` fill with `canvas` text.
public struct EffortSelector: View {
    @Binding var selection: AryaEffort

    public init(selection: Binding<AryaEffort>) {
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: AryaSpace.s2) {
            Text("Effort").aryaText(AryaFont.caption, AryaColor.inkMuted)
            HStack(spacing: 0) {
                ForEach(Array(AryaEffort.allCases.enumerated()), id: \.element) { index, effort in
                    if index > 0 { AryaHairline(.vertical, color: AryaColor.ruleStrong) }
                    segment(effort)
                }
            }
            .frame(height: AryaSize.controlHeight)
            .clipShape(RoundedRectangle(cornerRadius: AryaRadius.small))
            .overlay {
                RoundedRectangle(cornerRadius: AryaRadius.small)
                    .strokeBorder(AryaColor.ruleStrong, lineWidth: 1)
            }
        }
        .help(AryaEffort.tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Effort")
    }

    private func segment(_ effort: AryaEffort) -> some View {
        let isSelected = effort == selection
        return Button {
            selection = effort
        } label: {
            Text(effort.label)
                .aryaText(
                    isSelected ? AryaFont.bodyStrong : AryaFont.body,
                    isSelected ? AryaColor.canvas : AryaColor.inkMuted
                )
                .padding(.horizontal, AryaSpace.s3)
                .frame(maxHeight: .infinity)
                .background(isSelected ? AryaColor.ink : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tab in a `TextTabBar`.
public struct TextTab<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public let count: Int

    public init(id: ID, title: String, count: Int = 0) {
        self.id = id
        self.title = title
        self.count = count
    }
}

/// Text tabs in `bodyStrong`, 24 pt apart, 36 pt tall, over a full-width hairline. The
/// selected tab is `ink` with a 2 pt `ink` underline flush with the hairline.
public struct TextTabBar<ID: Hashable>: View {
    let tabs: [TextTab<ID>]
    let inset: CGFloat
    @Binding var selection: ID

    /// - Parameter inset: leading inset of the tabs; the hairline still runs edge to edge.
    public init(tabs: [TextTab<ID>], selection: Binding<ID>, inset: CGFloat = 0) {
        self.tabs = tabs
        self.inset = inset
        self._selection = selection
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: AryaSpace.s5) {
            ForEach(tabs) { tab in
                TextTabButton(tab: tab, isSelected: tab.id == selection) { selection = tab.id }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, inset)
        .frame(height: AryaSize.tabBarHeight, alignment: .bottom)
        .aryaHairline(edge: .bottom)
    }
}

struct TextTabButton<ID: Hashable>: View {
    let tab: TextTab<ID>
    let isSelected: Bool
    let select: () -> Void
    @AryaState private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s1) {
                    Text(tab.title).aryaText(AryaFont.bodyStrong, titleColor)
                    CountLabel(tab.count)
                }
                Spacer(minLength: 0)
                Rectangle()
                    .fill(isSelected ? AryaColor.ink : .clear)
                    .frame(height: AryaSize.tabUnderline)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var titleColor: Color {
        isSelected || isHovering ? AryaColor.ink : AryaColor.inkMuted
    }
}

/// A short set of exclusive choices as plain text (STYLE.md Choices): the selected one in `ink`
/// with a check mark, the rest in `inkFaint`. No box, no fill, no second label; the section
/// label above names it.
/// A shortcut hint: small mono keys inside a 1 px rounded hairline, "⌘K", "esc".
public struct Keycap: View {
    let keys: String

    public init(_ keys: String) {
        self.keys = keys
    }

    public var body: some View {
        Text(keys)
            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            .padding(.horizontal, AryaSpace.s1)
            .overlay(
                RoundedRectangle(cornerRadius: AryaRadius.small)
                    .strokeBorder(AryaColor.rule, lineWidth: 1)
            )
            .accessibilityLabel("Shortcut \(keys)")
    }
}

public struct ChoiceRow<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value
    let choose: (Value) -> Void

    public init(
        _ options: [(value: Value, title: String)], selection: Value,
        choose: @escaping (Value) -> Void
    ) {
        self.options = options
        self.selection = selection
        self.choose = choose
    }

    public var body: some View {
        HStack(spacing: AryaSpace.s4) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    choose(option.value)
                } label: {
                    HStack(spacing: AryaSpace.s1) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(isSelected ? 1 : 0)
                        Text(option.title)
                            .aryaText(
                                isSelected ? AryaFont.bodyStrong : AryaFont.body,
                                isSelected ? AryaColor.ink : AryaColor.inkFaint)
                    }
                    .foregroundStyle(isSelected ? AryaColor.ink : AryaColor.inkFaint)
                    .frame(height: AryaSize.controlHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// The small chevron before an expandable row: right when closed, down when open.
public struct DisclosureChevron: View {
    let isExpanded: Bool

    public init(isExpanded: Bool) { self.isExpanded = isExpanded }

    public var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(AryaColor.inkFaint)
            .frame(width: AryaSpace.s3)
            .accessibilityHidden(true)
    }
}
