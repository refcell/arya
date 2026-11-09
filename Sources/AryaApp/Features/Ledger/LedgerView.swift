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
                LedgerInspector(event: event, title: event.run.flatMap { table.runTitles[$0] }) {
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
                TextField("Search events", text: $filter.query)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.body, AryaColor.ink)
                filterMenu
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(LedgerText.count(table)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                Text("·").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                verifyStatus
                Spacer(minLength: 0)
            }
            FeatureWriteErrorLine(store: store)
        }
    }

    @ViewBuilder private var verifyStatus: some View {
        if store.isVerifying {
            Text("verifying…").aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
        } else if let result = store.verifyResult {
            Button(LedgerText.verifyStatus(result)) { Task { await store.verify() } }
                .buttonStyle(.plain)
                .aryaText(
                    AryaFont.monoSmall,
                    result.isIntact ? AryaColor.inkMuted : AryaColor.negative
                )
                .help(LedgerText.verify(result))
        } else {
            Button("verify chain") { Task { await store.verify() } }
                .buttonStyle(.plain)
                .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
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

    var body: some View {
        if table.rows.isEmpty {
            Text("No events match. Clear the search or a filter to see more.")
                .aryaText(AryaFont.body, AryaColor.inkMuted)
                .padding(AryaSpace.s5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.element.id) { index, event in
                        row(event, repeatsRun: index > 0 && table.rows[index - 1].run == event.run)
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
            Text(AryaTime.clock(event.at))
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

/// The selected event's machine detail: ids, hash, actor, and the payload pretty-printed.
private struct LedgerInspector: View {
    var event: FeatureEvent
    var title: String?
    var close: () -> Void

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
                if let title { Text(title).aryaText(AryaFont.body, AryaColor.inkMuted) }
                ForEach(LedgerText.detail(event), id: \.label) { field in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(field.label).aryaText(AryaFont.overline, AryaColor.inkFaint)
                        Text(field.value).aryaText(AryaFont.monoSmall, AryaColor.ink)
                            .textSelection(.enabled)
                    }
                }
                Text("Payload").aryaText(AryaFont.overline, AryaColor.inkFaint)
                MachineText(event.payload.prettyText)
            }
            .padding(AryaSpace.s4)
        }
    }
}
