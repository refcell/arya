import SwiftUI

/// The effort selector: `Effort` in `caption`/`inkMuted` and an `AryaSegmented` of three.
public struct EffortSelector: View {
    @Binding var selection: AryaEffort

    public init(selection: Binding<AryaEffort>) {
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: AryaSpace.s2) {
            Text("Effort").aryaText(AryaFont.caption, AryaColor.inkMuted)
            AryaSegmented(
                AryaEffort.allCases.map { ($0, $0.label) }, selection: selection
            ) { selection = $0 }
        }
        .help(AryaEffort.tooltip)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Effort")
    }
}

/// A segmented control (STYLE.md Controls): 24 pt, a hairline outline, segments split by
/// hairlines, the selected one an `ink` fill with `canvas` text so the choice reads at a
/// glance. Hover lifts an unselected segment to `raised`.
public struct AryaSegmented<Value: Hashable>: View {
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
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { AryaHairline(.vertical, color: AryaColor.ruleStrong) }
                AryaSegment(title: option.title, isSelected: option.value == selection) {
                    choose(option.value)
                }
            }
        }
        .frame(height: AryaSize.buttonHeight)
        .fixedSize(horizontal: true, vertical: false)
        .clipShape(RoundedRectangle(cornerRadius: AryaRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: AryaRadius.small)
                .strokeBorder(AryaColor.ruleStrong, lineWidth: 1)
        }
    }
}

struct AryaSegment: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @AryaState private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .aryaText(
                    isSelected ? AryaFont.bodyStrong : AryaFont.body,
                    isSelected ? AryaColor.canvas : isHovered ? AryaColor.ink : AryaColor.inkMuted
                )
                .padding(.horizontal, AryaSpace.s2 + AryaSpace.s1)
                .frame(maxHeight: .infinity)
                .background(isSelected ? AryaColor.ink : isHovered ? AryaColor.raised : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(AryaMotion.quick, value: isSelected)
        .accessibilityLabel(title)
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

/// A short set of exclusive choices: an `AryaSegmented` (STYLE.md Controls).
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
        AryaSegmented(options, selection: selection, choose: choose)
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
