import AppKit
import AryaDesign
import SwiftUI

/// The ledger: every event as one mono line (seq, time, type, and the run's title), one
/// search field and a filter menu, Verify as a quiet status line, and a row click opening the
/// inspector with ids, hash, and the payload.
struct LedgerView: View {
    @ObservedObject var store: FeatureStore
    /// The selected steward; nil shows every steward's events with a steward column.
    var steward: String?
    /// The selected event when the shell drives it (navigation, snapshots); else local.
    var selection: Binding<String?>?
    /// Opens a run's thread (run, steward) from the inspector.
    var openRun: ((String, String) -> Void)?
    @AryaState private var filter = LedgerFilter.all
    @AryaState private var localSelection: String?

    private var selected: Binding<String?> { selection ?? $localSelection }

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading the ledger.", guidance: "Reading every event in order.")
        case .failed(let message):
            EmptyState(
                "The ledger could not be read.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events) where events.isEmpty:
            EmptyState(
                "The ledger is empty.",
                guidance: "Every trigger, decision, action, and approval is recorded here.")
        case .loaded(let events):
            content(table(events))
        }
    }

    /// The table for the current filter, scoped to the selected steward when there is one.
    private func table(_ events: [FeatureEvent]) -> LedgerTable {
        var scoped = filter
        if let steward { scoped.steward = steward }
        return LedgerTable.build(events: events, filter: scoped)
    }

    private func content(_ table: LedgerTable) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                LedgerToolbar(store: store, table: table, filter: $filter, scoped: steward != nil)
                    .padding(.horizontal, AryaSpace.s5)
                    .padding(.vertical, AryaSpace.s3)
                LedgerRows(
                    table: table, showsSteward: steward == nil, selected: selected)
            }
            if let event = table.rows.first(where: { $0.id == selected.wrappedValue }) {
                AryaHairline(.vertical)
                LedgerInspector(
                    store: store, event: event, title: event.run.flatMap { table.runTitles[$0] },
                    openRun: openRun
                ) {
                    selected.wrappedValue = nil
                }
                .frame(width: AryaSize.readingWidth / 2)
            }
        }
        .background(AryaColor.canvas)
    }
}

private struct LedgerToolbar: View {
    @ObservedObject var store: FeatureStore
    var table: LedgerTable
    @Binding var filter: LedgerFilter
    var scoped: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                VStack(alignment: .leading, spacing: AryaSpace.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        Image(systemName: "magnifyingglass")
                            .aryaText(AryaFont.caption, AryaColor.inkFaint)
                            .accessibilityHidden(true)
                        TextField("Search events", text: $filter.query)
                            .textFieldStyle(.plain)
                            .aryaText(AryaFont.body, AryaColor.ink)
                    }
                    AryaHairline()
                }
                filterMenu
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                verifyStatus
                Spacer(minLength: 0)
            }
            FeatureWriteErrorLine(store: store)
        }
    }

    /// Before verifying: the count and a quiet Verify. After: the result as a status.
    @ViewBuilder private var verifyStatus: some View {
        if store.isVerifying {
            Text("verifying…").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        } else if let result = store.verifyResult {
            Text(LedgerText.verifyStatus(result, total: table.total))
                .aryaText(
                    AryaFont.monoSmall, result.isIntact ? AryaColor.inkMuted : AryaColor.negative
                )
                .help(LedgerText.verify(result))
        } else {
            Text(LedgerText.count(table)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            Button("Verify") { Task { await store.verify() } }
                .buttonStyle(.aryaTertiary)
                .help("Check every hash and sequence number in the ledger")
        }
    }

    private var filterMenu: some View {
        Menu(filter.isFiltered ? "Filtered" : "Filter") {
            Section("Type") {
                ForEach(table.namespaces, id: \.self) { value in
                    toggle(value, current: filter.type) { filter.type = $0 }
                }
            }
            Section("Actor") {
                ForEach(table.actors, id: \.self) { value in
                    toggle(value, current: filter.actor) { filter.actor = $0 }
                }
            }
            if !scoped {
                Section("Steward") {
                    ForEach(table.stewards, id: \.self) { value in
                        toggle(value, current: filter.steward) { filter.steward = $0 }
                    }
                }
            }
            if filter.isFiltered {
                Divider()
                Button("Clear filters") {
                    let query = filter.query
                    filter = .all
                    filter.query = query
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .aryaText(AryaFont.caption, AryaColor.inkMuted)
    }

    private func toggle(
        _ value: String, current: String?, set: @escaping (String?) -> Void
    ) -> some View {
        Button {
            set(current == value ? nil : value)
        } label: {
            if current == value { Label(value, systemImage: "checkmark") } else { Text(value) }
        }
    }
}

private struct LedgerRows: View {
    var table: LedgerTable
    var showsSteward: Bool
    @Binding var selected: String?
    @AryaState private var expanded: Set<String> = []

    private func run(_ line: LedgerLine) -> String? {
        switch line {
        case .event(let event): event.run
        case .adapterRun(_, let events): events.first?.run
        }
    }

    /// A collapsed run of adapter events: one quiet line that expands in place.
    private func folded(_ id: String, _ events: [FeatureEvent], repeatsRun: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
            Text(LedgerText.pad("", table.seqWidth)).aryaText(
                AryaFont.monoSmall, AryaColor.inkFaint
            )
            .fixedSize()
            Text(StreamStepText.clock(events[0].at)).aryaText(
                AryaFont.monoSmall, AryaColor.inkFaint
            )
            .fixedSize()
            Text(LedgerText.pad("\(events.count) adapter events", table.typeWidth))
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted).fixedSize()
            Text(repeatsRun ? "" : LedgerText.runLabel(events[0], titles: table.runTitles))
                .aryaText(AryaFont.caption, AryaColor.inkMuted)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AryaSpace.s1)
        .padding(.horizontal, AryaSpace.s2)
        .contentShape(Rectangle())
        .onTapGesture { expanded.insert(id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows each adapter event")
    }

    var body: some View {
        if table.rows.isEmpty {
            Text("No events match. Clear the search or a filter to see more.")
                .aryaText(AryaFont.body, AryaColor.inkMuted)
                .padding(AryaSpace.s5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let lines = table.lines(expanded: expanded)
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let repeats = index > 0 && run(lines[index - 1]) == run(line)
                        switch line {
                        case .event(let event): row(event, repeatsRun: repeats)
                        case .adapterRun(_, let events):
                            folded(line.id, events, repeatsRun: repeats)
                        }
                    }
                    if table.rows.count == table.scopedTotal,
                        let note = LedgerText.outOfScope(table)
                    {
                        Text(note).aryaText(AryaFont.caption, AryaColor.inkFaint)
                            .padding(.horizontal, AryaSpace.s2)
                            .padding(.vertical, AryaSpace.s3)
                    }
                }
                .padding(.horizontal, AryaSpace.s3)
            }
        }
    }

    /// One event; the run title shows only where the run changes, so a run reads as a block.
    private func row(_ event: FeatureEvent, repeatsRun: Bool) -> some View {
        let isSelected = selected == event.id
        return HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
            Text(LedgerText.pad(String(event.seq), table.seqWidth, leading: true))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint).fixedSize()
            Text(StreamStepText.clock(event.at))
                .aryaText(AryaFont.monoSmall, AryaColor.inkFaint).fixedSize()
                .help(FeatureTime.absolute(event.at))
            Text(LedgerText.pad(event.type, table.typeWidth))
                .aryaText(AryaFont.monoSmall, AryaColor.ink).fixedSize()
            if showsSteward {
                Text(event.steward ?? "—").aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                    .lineLimit(1).fixedSize()
            }
            Text(repeatsRun ? "" : LedgerText.runLabel(event, titles: table.runTitles))
                .aryaText(AryaFont.caption, AryaColor.inkMuted)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AryaSpace.s1)
        .padding(.horizontal, AryaSpace.s2)
        .background(
            isSelected ? AryaColor.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: AryaRadius.small)
        )
        .contentShape(Rectangle())
        .onTapGesture { selected = isSelected ? nil : event.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The selected event: what it is in words (type, time, actor, its place in a run with a link
/// there), then the machine detail (payload pretty-printed, hash, prev). The detail comes from
/// the workspace's event read, else from the event already loaded.
private struct LedgerInspector: View {
    @ObservedObject var store: FeatureStore
    var event: FeatureEvent
    var title: String?
    var openRun: ((String, String) -> Void)?
    var close: () -> Void
    private var detail: FeatureEventDetail? { store.eventDetails[event.seq] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.type).aryaText(AryaFont.mono, AryaColor.ink)
                    Spacer(minLength: AryaSpace.s2)
                    Button("Close", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .aryaText(AryaFont.caption, AryaColor.inkFaint)
                }
                Text(AryaTime.label(event.at, now: store.now))
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
                field("Actor", LedgerTable.actorLabel(event.actor))
                runLink
                Text("Payload").aryaText(AryaFont.overline, AryaColor.inkFaint)
                MachineText(detail?.payloadText ?? event.payload.prettyText)
                field("Seq", String(event.seq))
                field("Id", event.id)
                chain("Hash", detail?.hash ?? event.hash)
                chain("Prev", detail?.prev ?? "")
            }
            .padding(AryaSpace.s4)
        }
        .task(id: event.seq) { await store.loadEventDetail(seq: event.seq) }
    }

    @ViewBuilder private var runLink: some View {
        if let run = event.run {
            let words = LedgerText.step(detail?.step, title: title, run: run)
            VStack(alignment: .leading, spacing: 0) {
                Text("Run").aryaText(AryaFont.overline, AryaColor.inkFaint)
                if let openRun, let steward = event.steward {
                    Button(words) { openRun(run, steward) }
                        .buttonStyle(.plain)
                        .aryaText(AryaFont.body, AryaColor.ink)
                        .help("Open this run's thread")
                } else {
                    Text(words).aryaText(AryaFont.body, AryaColor.ink)
                }
            }
        }
    }

    /// A hash-chain value on one line, truncated in the middle; the full value is on hover,
    /// selectable, and in the context menu. The first event's prev is the empty string.
    private func chain(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).aryaText(AryaFont.overline, AryaColor.inkFaint)
            Text(LedgerText.chainValue(value, label: label))
                .aryaText(AryaFont.monoSmall, value.isEmpty ? AryaColor.inkFaint : AryaColor.ink)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .contextMenu {
                    Button("Copy \(label.lowercased())") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value, forType: .string)
                    }
                    .disabled(value.isEmpty)
                }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).aryaText(AryaFont.overline, AryaColor.inkFaint)
            Text(value).aryaText(AryaFont.monoSmall, AryaColor.ink).textSelection(.enabled)
        }
    }
}
