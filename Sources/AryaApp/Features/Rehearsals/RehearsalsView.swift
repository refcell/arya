import AryaDesign
import SwiftUI

/// Rehearsals: per-case results, expected versus actual, corrections, and Mark ready.
struct RehearsalsView: View {
    @ObservedObject var store: FeatureStore
    var steward: String?
    @AryaState private var chosen: String?
    @AryaState private var selectedCase: String?

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading rehearsals.", guidance: "Reading scored cases from the ledger.")
        case .failed(let message):
            EmptyState(
                "Rehearsals could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            content(RehearsalList.build(events: events, steward: steward), events: events)
        }
    }

    @ViewBuilder
    private func content(_ list: RehearsalList, events: [FeatureEvent]) -> some View {
        if let item = list.rehearsals.first(where: { $0.id == chosen }) ?? list.rehearsals.first {
            VStack(alignment: .leading, spacing: 0) {
                RehearsalHeader(
                    store: store, list: list, item: item,
                    chosen: Binding(
                        get: { item.id },
                        set: {
                            chosen = $0; selectedCase = nil
                        })
                )
                .padding(AryaSpace.s5)
                AryaHairline()
                HStack(alignment: .top, spacing: 0) {
                    CaseTable(item: item, selected: $selectedCase)
                    if let result = item.cases.first(where: { $0.id == selectedCase }) {
                        AryaHairline(.vertical)
                        CaseReview(store: store, item: item, result: result, events: events)
                            .id("\(item.id)/\(result.id)")
                            .frame(width: AryaSize.readingWidth * 2 / 3)
                    }
                }
            }
            .background(AryaColor.canvas)
        } else {
            if let steward {
                EmptyState(
                    "No rehearsals yet.",
                    guidance:
                        "Rehearse the steward on its casebook to see what it would have done.",
                    actionTitle: "Rehearse",
                    action: {
                        Task { await store.perform(.rehearse(steward: steward, casebook: nil)) }
                    })
            } else {
                EmptyState(
                    "No rehearsals yet.",
                    guidance: "Rehearse the steward on its casebook to see what it would have done."
                )
            }
        }
    }
}

private struct RehearsalHeader: View {
    @ObservedObject var store: FeatureStore
    var list: RehearsalList
    var item: RehearsalItem
    @Binding var chosen: String

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                if list.rehearsals.count > 1 {
                    Picker("Rehearsal", selection: $chosen) {
                        ForEach(list.rehearsals) { Text($0.id).tag($0.id) }
                    }
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
                    .fixedSize()
                } else {
                    Text(item.id).aryaText(AryaFont.mono, AryaColor.ink)
                }
                Text(RehearsalsText.totals(item)).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                    .monospacedDigit()
                Spacer(minLength: AryaSpace.s3)
                if let steward = item.steward {
                    Button("Rehearse again") {
                        Task { await store.perform(.rehearse(steward: steward, casebook: nil)) }
                    }
                    .buttonStyle(.aryaSecondary)
                    .help("Run every case of the newest casebook against the live charter.")
                }
                readiness
            }
            Text(RehearsalsText.meta(item)).aryaText(AryaFont.caption, AryaColor.inkFaint)
            FeatureWriteErrorLine(store: store)
        }
    }

    @ViewBuilder private var readiness: some View {
        if let mark = list.readyMark(steward: item.steward, charterVersion: item.charterVersion) {
            StatusBadge(.passed)
            Text(RehearsalsText.ready(mark, now: store.now))
                .aryaText(AryaFont.caption, AryaColor.inkMuted)
        } else if let steward = item.steward, item.proposal == nil {
            Button("Mark ready") {
                Task {
                    await store.perform(
                        .markReady(
                            steward: steward, charterVersion: item.charterVersion,
                            rehearsal: item.id))
                }
            }
            .buttonStyle(.aryaPrimary)
            .disabled(!list.canMarkReady(item))
            .help("Let this steward take live triggers with charter v\(item.charterVersion).")
        }
    }
}

private struct CaseTable: View {
    var item: RehearsalItem
    @Binding var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("case").frame(width: AryaSpace.s7 * 2, alignment: .leading)
                Text("result").frame(width: AryaSpace.s7 * 2, alignment: .leading)
                Text("score").frame(width: AryaSpace.s7, alignment: .trailing)
                Text("notes").padding(.leading, AryaSpace.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .aryaText(AryaFont.caption, AryaColor.inkMuted)
            .padding(.horizontal, AryaSpace.s3)
            .padding(.vertical, AryaSpace.s2)
            .aryaHairline(edge: .bottom, color: AryaColor.ruleStrong)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(item.cases) { result in row(result) }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ result: CaseResult) -> some View {
        TableRowFrame(isSelected: selected == result.id) {
            Text(result.id).aryaText(AryaFont.monoSmall, AryaColor.ink)
                .frame(width: AryaSpace.s7 * 2, alignment: .leading)
            StatusBadge(result.leak ? .failed : (result.passed ? .passed : .failed))
                .frame(width: AryaSpace.s7 * 2, alignment: .leading)
                .accessibilityLabel(RehearsalsText.status(result))
            Text(ChangesText.score(result.meanValue)).aryaText(AryaFont.monoSmall, AryaColor.ink)
                .frame(width: AryaSpace.s7, alignment: .trailing)
            Text(
                result.leak
                    ? "leak: " + result.notes.joined(separator: "; ")
                    : result.notes.joined(separator: "; ")
            )
            .aryaText(AryaFont.caption, AryaColor.inkMuted).lineLimit(1)
            .padding(.leading, AryaSpace.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = selected == result.id ? nil : result.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected == result.id ? [.isButton, .isSelected] : .isButton)
    }
}

private struct CaseReview: View {
    @ObservedObject var store: FeatureStore
    var item: RehearsalItem
    var result: CaseResult
    var events: [FeatureEvent]
    @AryaState private var expected = ExpectationState.loading
    @AryaState private var correction = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AryaSpace.s4) {
                Text(result.id).aryaText(AryaFont.title, AryaColor.ink)
                HStack(alignment: .top, spacing: AryaSpace.s5) {
                    column("Expected", expectedOutcome, note: expectedNote)
                    column("Actual", actual, note: result.firstRun.map { "from \($0)" })
                }
                if !result.notes.isEmpty {
                    Text(result.notes.joined(separator: "\n"))
                        .aryaText(AryaFont.body, AryaColor.inkMuted)
                }
                corrections
                correctionForm
            }
            .padding(AryaSpace.s5)
        }
        .task(id: result.corrections.count) {
            expected = await CaseExpectationLoader.load(
                store.workspace, casebook: item.casebook, result: result)
        }
    }

    private var actual: CaseOutcome? {
        result.firstRun.map { CaseOutcome.actual(events: events, run: $0) }
    }

    private var expectedOutcome: CaseOutcome? {
        if case .loaded(let outcome, _) = expected { return outcome }
        return nil
    }

    private var expectedNote: String? {
        switch expected {
        case .loading: return "Loading the casebook."
        case .loaded(_, let corrected): return corrected ? "from a correction" : "from the casebook"
        case .missing: return "Not in the casebook."
        case .failed(let message): return message
        }
    }

    private func column(_ title: String, _ outcome: CaseOutcome?, note: String?) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title).aryaText(AryaFont.caption, AryaColor.inkMuted)
            if let outcome {
                ForEach(outcome.decisions, id: \.self) {
                    Text($0).aryaText(AryaFont.heading, AryaColor.ink)
                }
                ForEach(outcome.actions, id: \.self) {
                    Text($0).aryaText(AryaFont.mono, AryaColor.ink)
                }
            }
            if let note { Text(note).aryaText(AryaFont.caption, AryaColor.inkFaint) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var corrections: some View {
        ForEach(Array(result.corrections.enumerated()), id: \.offset) { _, record in
            Text("Corrected by \(record.by.id): \(record.text)")
                .aryaText(AryaFont.caption, AryaColor.inkMuted)
        }
    }

    private var correctionForm: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Text("Correction").aryaText(AryaFont.caption, AryaColor.inkMuted)
            TextField("What should the steward have done?", text: $correction, axis: .vertical)
                .textFieldStyle(.plain)
                .aryaText(AryaFont.body, AryaColor.ink)
                .padding(AryaSpace.s2)
                .background(AryaColor.sunken, in: RoundedRectangle(cornerRadius: AryaRadius.small))
            HStack {
                Spacer()
                Button("Record correction") { record() }
                    .buttonStyle(.aryaSecondary)
                    .disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Kept as a memory note, so the next rehearsal can learn from it.")
            }
        }
    }

    private func record() {
        guard let steward = item.steward else { return }
        let write = FeatureWrite.correctCase(
            CaseCorrection(
                steward: steward, casebook: item.casebook, caseID: result.id, text: correction,
                expected: nil, rehearsal: item.id, run: result.firstRun))
        Task {
            if await store.perform(write) { correction = "" }
        }
    }
}
