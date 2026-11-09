import AryaDesign
import SwiftUI

/// The ledger: every event, filterable by steward, run, type, and actor, with an event detail
/// pane and a Verify button that checks the hash chain.
struct LedgerView: View {
    @ObservedObject var store: FeatureStore
    @AryaState private var filter = LedgerFilter.all
    @AryaState private var selected: String?

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
            content(LedgerTable.build(events: events, filter: filter))
        }
    }

    private func content(_ table: LedgerTable) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LedgerToolbar(store: store, table: table, filter: $filter)
                .padding(AryaSpace.s5)
            AryaHairline()
            HStack(alignment: .top, spacing: 0) {
                LedgerRows(table: table, now: store.now, selected: $selected)
                if let event = table.rows.first(where: { $0.id == selected }) {
                    AryaHairline(.vertical)
                    LedgerDetail(event: event)
                        .frame(width: AryaSize.readingWidth / 2)
                }
            }
        }
        .background(AryaColor.canvas)
    }
}

private struct LedgerToolbar: View {
    @ObservedObject var store: FeatureStore
    var table: LedgerTable
    @Binding var filter: LedgerFilter

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            HStack(spacing: AryaSpace.s3) {
                picker("Steward", table.stewards, $filter.steward)
                picker("Run", table.runs, $filter.run)
                picker("Type", table.namespaces, $filter.type)
                picker("Actor", table.actors, $filter.actor)
                if filter.isActive {
                    Button("Clear filters") { filter = .all }.buttonStyle(.aryaTertiary)
                }
                Spacer(minLength: AryaSpace.s3)
                Button(store.isVerifying ? "Verifying" : "Verify") {
                    Task { await store.verify() }
                }
                .buttonStyle(.aryaSecondary)
                .disabled(store.isVerifying)
                .help("Check every hash and sequence number in the ledger")
            }
            HStack(spacing: AryaSpace.s3) {
                Text(LedgerText.count(table)).aryaText(AryaFont.caption, AryaColor.inkFaint)
                if let result = store.verifyResult { VerifyLine(result: result) }
            }
            FeatureWriteErrorLine(store: store)
        }
    }

    private func picker(
        _ title: String, _ values: [String], _ selection: Binding<String?>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("All").tag(String?.none)
            ForEach(values, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .aryaText(AryaFont.caption, AryaColor.inkMuted)
        .fixedSize()
    }
}

private struct VerifyLine: View {
    var result: FeatureVerifyResult

    var body: some View {
        switch result {
        case .intact:
            HStack(spacing: AryaSpace.s1) {
                StatusDot(.passed)
                Text(LedgerText.verify(result)).aryaText(AryaFont.caption, AryaColor.positive)
            }
        case .broken:
            HStack(spacing: AryaSpace.s1) {
                StatusDot(.failed)
                Text(LedgerText.verify(result)).aryaText(AryaFont.caption, AryaColor.negative)
            }
        }
    }
}

/// Column widths on the 4 pt grid.
private enum LedgerColumn {
    static let seq = AryaSpace.s7
    static let time = AryaSpace.s7 + AryaSpace.s4
    static let type = AryaSpace.s7 * 3
    static let steward = AryaSpace.s7 * 2
    static let run = AryaSpace.s7 * 2
}

private struct LedgerRows: View {
    var table: LedgerTable
    var now: Date
    @Binding var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if table.rows.isEmpty {
                EmptyState(
                    "No events match.", guidance: "Clear a filter to see more of the ledger.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(table.rows) { event in row(event) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 0) {
            cell("seq", LedgerColumn.seq, .trailing)
            cell("time", LedgerColumn.time)
            cell("type", LedgerColumn.type)
            cell("steward", LedgerColumn.steward)
            cell("run", LedgerColumn.run)
            Text("actor").frame(maxWidth: .infinity, alignment: .leading)
        }
        .aryaText(AryaFont.caption, AryaColor.inkMuted)
        .padding(.horizontal, AryaSpace.s3)
        .padding(.vertical, AryaSpace.s2)
        .aryaHairline(edge: .bottom, color: AryaColor.ruleStrong)
    }

    private func row(_ event: FeatureEvent) -> some View {
        TableRowFrame(isSelected: selected == event.id) {
            cell(String(event.seq), LedgerColumn.seq, .trailing).monospacedDigit()
            cell(FeatureTime.relative(event.at, now: now), LedgerColumn.time)
                .help(FeatureTime.absolute(event.at))
            cell(event.type, LedgerColumn.type)
            cell(event.steward ?? "—", LedgerColumn.steward)
            cell(event.run ?? "—", LedgerColumn.run)
            Text(LedgerTable.actorLabel(event.actor))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .aryaText(AryaFont.monoSmall, AryaColor.ink)
        .contentShape(Rectangle())
        .onTapGesture { selected = selected == event.id ? nil : event.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected == event.id ? [.isButton, .isSelected] : .isButton)
    }

    private func cell(
        _ text: String, _ width: CGFloat, _ alignment: Alignment = .leading
    ) -> some View {
        Text(text).lineLimit(1).truncationMode(.middle)
            .padding(.trailing, AryaSpace.s3)
            .frame(width: width, alignment: alignment)
    }
}

private struct LedgerDetail: View {
    var event: FeatureEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s3) {
                Text(event.type).aryaText(AryaFont.heading, AryaColor.ink)
                ForEach(LedgerText.detail(event), id: \.label) { field in
                    HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                        Text(field.label).aryaText(AryaFont.caption, AryaColor.inkMuted)
                            .frame(width: AryaSpace.s7 + AryaSpace.s2, alignment: .leading)
                        Text(field.value).aryaText(AryaFont.monoSmall, AryaColor.ink)
                            .textSelection(.enabled)
                    }
                }
                Text("payload").aryaText(AryaFont.caption, AryaColor.inkMuted)
                CodeBlock(event.payload.compactText)
            }
            .padding(AryaSpace.s5)
        }
    }
}
