import AryaDesign
import SwiftUI

/// Improve: the latest rehearsal in one line, its cases (each expanding to what the steward
/// would have done against what was expected, with Correct), and the open proposals.
/// Mark ready is the one primary action; history sits behind a quiet menu.
struct ImproveView: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    @AryaState private var chosen: String?
    @AryaState private var expanded: String?

    var body: some View {
        switch store.state {
        case .loading:
            EmptyState("Loading.", guidance: "Reading rehearsals and proposals from the ledger.")
        case .failed(let message):
            EmptyState(
                "Improve could not be loaded.", guidance: message, actionTitle: "Retry",
                action: { Task { await store.reload() } })
        case .loaded(let events):
            ScrollView {
                VStack(alignment: .leading, spacing: AryaSpace.s5) {
                    FeatureWriteErrorLine(store: store)
                    rehearsal(RehearsalList.build(events: events, steward: steward), events: events)
                    AryaHairline()
                    ImproveProposals(
                        store: store, list: ChangeList.build(events: events, steward: steward))
                }
                .frame(maxWidth: AryaSize.readingWidth, alignment: .leading)
                .padding(.horizontal, AryaSpace.s5)
                .padding(.vertical, AryaSpace.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AryaColor.canvas)
        }
    }

    @ViewBuilder
    private func rehearsal(_ list: RehearsalList, events: [FeatureEvent]) -> some View {
        if let item = list.rehearsals.first(where: { $0.id == chosen }) ?? list.rehearsals.first {
            let mark = list.readyMark(steward: item.steward, charterVersion: item.charterVersion)
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                    Text(ImproveText.summary(item, ready: mark, now: store.now))
                        .aryaText(AryaFont.bodyStrong, AryaColor.ink).monospacedDigit()
                    Spacer(minLength: AryaSpace.s3)
                    if list.rehearsals.count > 1 { history(list) }
                    Button("Rehearse again") { rehearse() }
                        .buttonStyle(.aryaSecondary)
                        .help("Run every case of the newest casebook against the live charter.")
                    if list.canMarkReady(item) {
                        Button("Mark ready") { markReady(item) }
                            .buttonStyle(.aryaPrimary)
                            .help("Let this steward take live triggers with this charter.")
                    }
                }
                Text(ImproveText.meta(item)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            }
            VStack(alignment: .leading, spacing: 0) {
                let scores = ImproveText.showsScores(item)
                ForEach(item.cases) { result in
                    CaseLine(
                        store: store, item: item, result: result, events: events,
                        showsScore: scores,
                        isExpanded: expanded == result.id
                    ) { expanded = expanded == result.id ? nil : result.id }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                Text("No rehearsals yet. Rehearse to see what the steward would have done.")
                    .aryaText(AryaFont.body, AryaColor.inkMuted)
                Spacer(minLength: AryaSpace.s3)
                Button("Rehearse") { rehearse() }.buttonStyle(.aryaSecondary)
            }
        }
    }

    private func history(_ list: RehearsalList) -> some View {
        Menu("History") {
            ForEach(list.rehearsals) { item in
                Button(ImproveText.historyLabel(item, now: store.now)) {
                    chosen = item.id
                    expanded = nil
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .aryaText(AryaFont.caption, AryaColor.inkMuted)
    }

    private func rehearse() {
        Task { await store.perform(.rehearse(steward: steward, casebook: nil)) }
    }

    private func markReady(_ item: RehearsalItem) {
        Task {
            await store.perform(
                .markReady(
                    steward: steward, charterVersion: item.charterVersion, rehearsal: item.id))
        }
    }
}

/// One case: a pass or fail mark, the case id, and what the steward would have done; it
/// expands to the expected result, notes, corrections, and Correct.
private struct CaseLine: View {
    @ObservedObject var store: FeatureStore
    var item: RehearsalItem
    var result: CaseResult
    var events: [FeatureEvent]
    var showsScore: Bool
    var isExpanded: Bool
    var toggle: () -> Void
    @AryaState private var expected = ExpectationState.loading
    @AryaState private var correction = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    MarkGlyph(mark: result.passed ? .ok : .failed)
                    Text(result.id).aryaText(AryaFont.mono, AryaColor.ink)
                    Text(ImproveText.wouldHaveDone(result, events: events))
                        .aryaText(AryaFont.monoSmall, AryaColor.inkMuted)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: AryaSpace.s2)
                    if showsScore {
                        Text(ChangesText.score(result.meanValue))
                            .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
                }
                .padding(.vertical, AryaSpace.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(result.id), \(RehearsalsText.status(result))")
            if isExpanded { detail.padding(.leading, AryaSpace.s5).padding(.bottom, AryaSpace.s3) }
        }
        .task(id: "\(isExpanded)/\(result.corrections.count)") {
            guard isExpanded else { return }
            expected = await CaseExpectationLoader.load(
                store.workspace, casebook: item.casebook, result: result)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            labeled("Would have done", ImproveText.wouldHaveDone(result, events: events))
            labeled("Expected", expectedText, note: expectedNote)
            if result.leak {
                Text("The run read the expected answer, so this case cannot pass.")
                    .aryaText(AryaFont.caption, AryaColor.negative)
            }
            if !result.notes.isEmpty {
                Text(result.notes.joined(separator: "\n")).aryaText(
                    AryaFont.body, AryaColor.inkMuted)
            }
            ForEach(Array(result.corrections.enumerated()), id: \.offset) { _, record in
                Text("Corrected by \(record.by.id): \(record.text)")
                    .aryaText(AryaFont.caption, AryaColor.inkMuted)
            }
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                TextField("What should it have done?", text: $correction, axis: .vertical)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.body, AryaColor.ink)
                Button("Correct") { record() }
                    .buttonStyle(.aryaSecondary)
                    .disabled(correction.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Kept as a memory note, so the next rehearsal can learn from it.")
            }
            .padding(.top, AryaSpace.s1)
        }
    }

    private func labeled(_ title: String, _ text: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            Text(title).aryaText(AryaFont.overline, AryaColor.inkFaint)
            Text(text).aryaText(AryaFont.mono, AryaColor.ink).textSelection(.enabled)
            if let note { Text(note).aryaText(AryaFont.caption, AryaColor.inkFaint) }
        }
    }

    private var expectedText: String {
        switch expected {
        case .loading: "…"
        case .loaded(let outcome, _): outcome.text
        case .missing: "not in the casebook"
        case .failed(let message): message
        }
    }

    private var expectedNote: String? {
        if case .loaded(_, true) = expected { return "from a correction" }
        return nil
    }

    private func record() {
        let write = FeatureWrite.correctCase(
            CaseCorrection(
                steward: steward, casebook: item.casebook, caseID: result.id, text: correction,
                expected: nil, rehearsal: item.id, run: result.firstRun))
        Task {
            if await store.perform(write) { correction = "" }
        }
    }

    private var steward: String { item.steward ?? "" }
}

/// Proposed changes to the charter and routines, under the rehearsal: open ones with their
/// gate and quiet Accept and Reject, then one muted line for the closed count.
private struct ImproveProposals: View {
    @ObservedObject var store: FeatureStore
    var list: ChangeList

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            Text("Proposals").aryaText(AryaFont.overline, AryaColor.inkFaint)
            if list.open.isEmpty {
                Text(
                    list.closed.isEmpty
                        ? "No proposed changes."
                        : "No open proposals. \(list.closed.count) decided."
                )
                .aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            ForEach(list.open) { item in row(item) }
        }
    }

    private func row(_ item: ProposalItem) -> some View {
        VStack(alignment: .leading, spacing: AryaSpace.s1) {
            HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                Text(item.title).aryaText(AryaFont.bodyStrong, AryaColor.ink)
                Spacer(minLength: AryaSpace.s2)
                Button("Reject") { decide(.rejectProposal(item.id, reason: "")) }
                    .buttonStyle(.aryaSecondary)
                if item.canOverride {
                    Button("Accept anyway") {
                        decide(.overrideProposal(item.id, reason: "accepted over a failed gate"))
                    }
                    .buttonStyle(.aryaSecondary)
                    .help(
                        "Accept although the gate failed. The override is recorded with your name.")
                }
                Button("Accept") { decide(.acceptProposal(item.id)) }
                    .buttonStyle(.aryaSecondary)
                    .disabled(!item.canAccept)
            }
            if !item.reason.isEmpty {
                Text(item.reason).aryaText(AryaFont.body, AryaColor.inkMuted)
            }
            Text(ChangesText.gate(item.gate)).aryaText(AryaFont.monoSmall, AryaColor.inkFaint)
            if let regressions = ChangesText.regressions(item.gate) {
                Text(regressions).aryaText(AryaFont.monoSmall, AryaColor.negative)
            }
        }
        .padding(.vertical, AryaSpace.s1)
    }

    private func decide(_ write: FeatureWrite) {
        Task { await store.perform(write) }
    }
}
