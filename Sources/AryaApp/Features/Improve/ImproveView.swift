import AryaDesign
import SwiftUI

/// Improve: the latest rehearsal in one line, its cases (each expanding to what the steward
/// would have done against what was expected, with Correct), and the open proposals.
/// Mark ready is the one primary action; history sits behind a quiet menu.
struct ImproveView: View {
    @ObservedObject var store: FeatureStore
    var steward: String
    /// The steward is paused: Rehearse still works, scheduled runs are off.
    var paused = false
    @AryaState private var chosen: String?
    @AryaState private var expanded: String?
    /// The workspace's sentences for the newest rehearsal, when the workspace can write them.
    @AryaState private var summary: FeatureImproveSummary?

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
                VStack(alignment: .leading, spacing: AryaSpace.s4) {
                    FeatureWriteErrorLine(store: store)
                    rehearsal(RehearsalList.build(events: events, steward: steward), events: events)
                    if let queue = store.reviewQueues[steward] {
                        ReviewQueuePanel(store: store, steward: steward, queue: queue)
                    }
                    if let checks = store.learnedChecks[steward] {
                        LearnedChecksPanel(checks: checks)
                    }
                    if let worked = store.trajectories[steward] {
                        WhatWorkedPanel(trajectories: worked)
                    }
                    AryaHairline()
                    // Proposal review (app-outcome): change and why, rehearsal case by case,
                    // and Reject or Accept by what the rehearsal found.
                    OutcomeProposalsSection(
                        store: store, list: ChangeList.build(events: events, steward: steward),
                        events: events,
                        latestRun: ImproveText.latestLiveRun(events, steward: steward))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AryaSpace.s4)
                .padding(.vertical, AryaSpace.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AryaColor.canvas)
            .task(id: events.count) {
                summary = try? await store.workspace.improveSummary(steward: steward)
                if let queue = try? await store.workspace.reviewQueue(steward: steward) {
                    store.reviewQueues[steward] = queue
                }
                if let checks = try? await store.workspace.learnedChecks(steward: steward) {
                    store.learnedChecks[steward] = checks
                }
                if let worked = try? await store.workspace.trajectories(steward: steward) {
                    store.trajectories[steward] = worked
                }
            }
        }
    }

    @ViewBuilder
    private func rehearsal(_ list: RehearsalList, events: [FeatureEvent]) -> some View {
        if let item = list.rehearsals.first(where: { $0.id == chosen }) ?? list.rehearsals.first {
            let mark = list.readyMark(steward: item.steward, charterVersion: item.charterVersion)
            let written = summary?.rehearsal == item.id ? summary : nil
            VStack(alignment: .leading, spacing: AryaSpace.s1) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s3) {
                    Text(ImproveText.headline(item, written: written, ready: mark, now: store.now))
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
                ActionNote(store: store, paused: paused)
                if let written, !written.ready {
                    ForEach(written.readinessReasons, id: \.self) { reason in
                        Text(reason).aryaText(AryaFont.caption, AryaColor.inkMuted)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                let scores = ImproveText.showsScores(item)
                ForEach(item.cases) { result in
                    CaseLine(
                        store: store, item: item, result: result, events: events,
                        reviewed: written?.cases.first { $0.id == result.id }, showsScore: scores,
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
            ActionNote(store: store, paused: paused)
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
    /// The workspace's words for this case, when it wrote them.
    var reviewed: FeatureImproveSummary.Case?
    var showsScore: Bool
    var isExpanded: Bool
    var toggle: () -> Void
    @AryaState private var expected = ExpectationState.loading
    @AryaState private var correction = ""
    @AryaState private var choice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s2) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: AryaSpace.s2) {
                    MarkGlyph(mark: result.passed ? .ok : .failed)
                    Text(result.id).aryaText(AryaFont.mono, AryaColor.ink)
                    Text(ImproveText.choice(result, events: events))
                        .aryaText(AryaFont.body, AryaColor.inkMuted)
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
            if isExpanded { detail.padding(.leading, AryaSpace.s4).padding(.bottom, AryaSpace.s3) }
        }
        .task(id: "\(isExpanded)/\(result.corrections.count)") {
            guard isExpanded, reviewed == nil else { return }
            expected = await CaseExpectationLoader.load(
                store.workspace, casebook: item.casebook, result: result)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: AryaSpace.s3) {
            labeled(
                "Would have done",
                reviewed?.wouldHave ?? ImproveText.wouldHaveDone(result, events: events))
            labeled("Expected", reviewed?.expected ?? expectedText, note: expectedNote)
            if let diff = reviewed?.diff, diff != "matches expected" {
                labeled("Difference", diff)
            }
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
                TextField("Should have chosen", text: $choice)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.mono, AryaColor.ink)
                    .frame(maxWidth: AryaSize.readingWidth / 4)
                TextField("Note (optional)", text: $correction, axis: .vertical)
                    .textFieldStyle(.plain)
                    .aryaText(AryaFont.body, AryaColor.ink)
                Button("Correct") { record() }
                    .buttonStyle(.aryaSecondary)
                    .disabled(!canCorrect)
                    .help(
                        "Sets this case's expected choice; the note is kept as memory so the next "
                            + "rehearsal can learn from it.")
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

    private var canCorrect: Bool {
        !choice.trimmingCharacters(in: .whitespaces).isEmpty
            || !correction.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func record() {
        let picked = choice.trimmingCharacters(in: .whitespaces)
        let write = FeatureWrite.correctCase(
            CaseCorrection(
                steward: steward, casebook: item.casebook, caseID: result.id, text: correction,
                expected: picked.isEmpty ? nil : ImproveText.expected(result, choice: picked),
                rehearsal: item.id, run: result.firstRun))
        Task {
            if await store.perform(write) {
                correction = ""
                choice = ""
            }
        }
    }

    private var steward: String { item.steward ?? "" }
}
