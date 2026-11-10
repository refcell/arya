import AryaDesign
import SwiftUI

/// The right half of a run: what the steward did, as a developer would read it. Tools holds a
/// block per tool call, action, and delegation; Diff the changes as unified diffs; Log the
/// run's ledger events; Output the adapter's wire traffic, with a caret while the run is live.
struct WorkPane: View {
    @ObservedObject var store: FeatureStore
    var work: RunWork
    var running: Bool
    @Binding var tab: WorkTab
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabs
            AryaHairline()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, AryaSpace.s3)
                        .padding(.vertical, AryaSpace.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: AryaSpace.s1).id(WorkPane.bottom)
                }
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: AryaMotion.appearSeconds)) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
                .onChange(of: tab) { _, tab in
                    if tab == .log || tab == .output { proxy.scrollTo(WorkPane.bottom) }
                }
                .onChange(of: work.output.count) { _, _ in
                    if tab == .output || tab == .log { proxy.scrollTo(WorkPane.bottom) }
                }
            }
        }
        .background(AryaColor.canvas)
    }

    static let bottom = "work-bottom"
    /// Log lines shown under the Tools blocks.
    static let logTail = 12

    private var tabs: some View {
        HStack(spacing: AryaSpace.s3) {
            ForEach(WorkTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: AryaSpace.s1) {
                        Text(item.title.uppercased()).aryaText(
                            AryaFont.label, item == tab ? AryaColor.ink : AryaColor.inkFaint)
                        Text("\(work.count(item))").aryaText(
                            AryaFont.monoSmall,
                            item == tab ? AryaColor.inkMuted : AryaColor.inkFaint)
                    }
                    .padding(.vertical, AryaSpace.s2)
                    .overlay(alignment: .bottom) {
                        if item == tab {
                            Rectangle().fill(AryaColor.accent).frame(height: AryaSize.tabUnderline)
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(item.rawValue)")), modifiers: .option)
                .help("\(item.title) (⌥\(item.rawValue))")
                .accessibilityAddTraits(item == tab ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: 0)
            Keycap("⌥1-4")
        }
        .padding(.horizontal, AryaSpace.s3)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .tools:
            if work.blocks.isEmpty { empty("No tool calls or actions yet.") }
            ForEach(work.blocks) { block in
                WorkBlockView(block: block, selected: block.id == selection) {
                    selection = block.id
                }
                .id(block.id)
            }
            if !work.log.isEmpty {
                // The log tails under the blocks, so the pane reads as a working session.
                Text("LOG").aryaText(AryaFont.label, AryaColor.inkFaint)
                    .padding(.top, AryaSpace.s3).padding(.bottom, AryaSpace.s1)
                ForEach(work.log.suffix(WorkPane.logTail)) { WorkLineView(line: $0) }
                if running { BlinkingCaret() }
            }
        case .diff:
            if work.diffs.isEmpty { empty("This run changed nothing.") }
            ForEach(work.diffs) { diff in
                WorkDiffView(store: store, diff: diff, selected: diff.id == selection).id(diff.id)
            }
        case .log:
            if work.log.isEmpty { empty("No events yet.") }
            ForEach(work.log) { WorkLineView(line: $0) }
        case .output:
            if work.output.isEmpty && !running { empty("The adapter wrote nothing.") }
            ForEach(work.output) { WorkLineView(line: $0) }
            if running { BlinkingCaret() }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).aryaText(AryaFont.caption, AryaColor.inkFaint).padding(.vertical, AryaSpace.s2)
    }
}

/// A block's header line (mark, tool, target, duration) over its sections in mono.
private struct WorkBlockView: View {
    var block: WorkBlock
    var selected: Bool
    var select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                MarkGlyph(mark: block.mark)
                Text(block.title).aryaText(AryaFont.mono, AryaColor.ink)
                if let target = block.target {
                    Text(target).aryaText(AryaFont.mono, AryaColor.inkMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: AryaSpace.s2)
                Text(block.meta).aryaText(AryaFont.monoSmall, AryaColor.inkFaint).lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            ForEach(block.sections, id: \.self) { section in
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    Text(section.label).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                        .frame(width: AryaSize.stepGutter * 2, alignment: .trailing)
                    MachineText(section.text)
                }
            }
        }
        .padding(.vertical, AryaSpace.s2)
        .padding(.horizontal, AryaSpace.s2)
        .background(selected ? AryaColor.selection : .clear)
        .aryaHairline(edge: .bottom)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.title) \(block.target ?? "") \(block.meta)")
    }
}

/// A unified diff with its title and +/- counts; routine text loads from the workspace.
private struct WorkDiffView: View {
    @ObservedObject var store: FeatureStore
    var diff: WorkDiff
    var selected: Bool

    var body: some View {
        let text = store.routineDiffs[diff.id] ?? diff.text
        let shown = WorkDiff(id: diff.id, title: diff.title, text: text)
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(spacing: AryaSpace.s2) {
                Text(diff.title).aryaText(AryaFont.mono, AryaColor.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: AryaSpace.s2)
                Text("+\(shown.added)").aryaText(AryaFont.monoSmall, AryaColor.positive)
                Text("−\(shown.removed)").aryaText(AryaFont.monoSmall, AryaColor.negative)
            }
            if text.isEmpty {
                Text("Loading…").aryaText(AryaFont.caption, AryaColor.inkFaint)
            } else {
                DiffBlock(text)
            }
        }
        .padding(.vertical, AryaSpace.s2)
        .padding(.horizontal, AryaSpace.s2)
        .background(selected ? AryaColor.selection : .clear)
        .task(id: diff.id) { await store.loadRoutineDiff(diff) }
    }
}

/// One Log or Output line: time, tag, text, all mono.
private struct WorkLineView: View {
    var line: WorkLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
            Text(line.time).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            Text(line.tag).aryaText(AryaFont.monoSmall, tagColor).lineLimit(1)
            Text(line.text).aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                .lineLimit(6).truncationMode(.tail)
                .textSelection(.enabled)
        }
        .padding(.vertical, AryaSpace.s1 / 2)
    }

    private var tagColor: Color {
        switch line.tone {
        case .plain: AryaColor.ink
        case .sent: AryaColor.inkMuted
        case .received: AryaColor.positive
        case .failed: AryaColor.negative
        }
    }
}

/// A block caret that blinks while output may still arrive.
struct BlinkingCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Text("▍").aryaText(AryaFont.mono, on ? AryaColor.accent : AryaColor.inkFaint)
                .accessibilityLabel("Waiting for output")
        }
    }
}
