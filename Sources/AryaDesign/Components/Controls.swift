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
    @Binding var selection: ID

    public init(tabs: [TextTab<ID>], selection: Binding<ID>) {
        self.tabs = tabs
        self._selection = selection
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: AryaSpace.s5) {
            ForEach(tabs) { tab in
                TextTabButton(tab: tab, isSelected: tab.id == selection) { selection = tab.id }
            }
            Spacer(minLength: 0)
        }
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
