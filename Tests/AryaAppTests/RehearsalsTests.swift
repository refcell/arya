import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let events = PreviewFixtures.triage(now: now)

private func rehearsal(_ log: [FeatureEvent] = events) throws -> RehearsalItem {
    try #require(RehearsalList.build(events: log).rehearsals.first)
}

@Test func rehearsalSummarizesTotalsAndCases() throws {
    let item = try rehearsal()
    #expect(item.id == PreviewFixtures.rehearsal)
    #expect(item.isFinished)
    #expect(RehearsalsText.totals(item) == "Mean 0.50 · 1 of 3 passed · 1 leak")
    #expect(RehearsalsText.meta(item) == "charter v1 on casebook cb0001 · 1 sample")
    #expect(item.cases.map(\.id) == ["case-0003", "case-0007", "case-0009"])
    #expect(item.cases.map(RehearsalsText.status) == ["passed", "failed", "leak"])
    #expect(item.cases[1].notes == ["decisions.choice: expected bug, got question"])
    #expect(item.cases[2].firstRun == nil)
}

@Test func runningRehearsalCountsScoredCases() {
    var log = FeatureEventBuilder(start: now)
    log.add("rehearsal.started", ["rehearsal": "rh_x", "charterVersion": 2, "cases": 4])
    log.add("rehearsal.case.scored", ["rehearsal": "rh_x", "case": "c1", "scores": [], "runs": []])
    let item = RehearsalList.build(events: log.events).rehearsals[0]
    #expect(RehearsalsText.totals(item) == "Running, 1 of 4 cases scored")
    #expect(RehearsalList.build(events: log.events).canMarkReady(item) == false)
}

@Test func actualOutcomeComesFromTheRehearsalRun() throws {
    let failing = try rehearsal().cases[1]
    let actual = CaseOutcome.actual(events: events, run: try #require(failing.firstRun))
    #expect(actual == CaseOutcome(decisions: ["question"], actions: ["label tracker:ISSUE-7"]))
}

@Test func expectedComesFromTheCasebookUntilCorrected() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let failing = try rehearsal().cases[1]
    let loaded = await CaseExpectationLoader.load(
        workspace, casebook: PreviewFixtures.casebook, result: failing)
    let outcome = CaseOutcome(decisions: ["bug"], actions: ["label tracker:ISSUE-7"])
    #expect(loaded == .loaded(outcome, corrected: false))
    var corrected = failing
    corrected.corrections = [
        CorrectionRecord(
            text: "x", expected: ["decisions": [["choice": "feature"]]], by: .localUser, at: now)
    ]
    let fromCorrection = await CaseExpectationLoader.load(
        workspace, casebook: PreviewFixtures.casebook, result: corrected)
    #expect(
        fromCorrection == .loaded(CaseOutcome(decisions: ["feature"], actions: []), corrected: true)
    )
    var unknown = failing
    unknown.id = "case-none"
    #expect(
        await CaseExpectationLoader.load(
            workspace, casebook: PreviewFixtures.casebook, result: unknown)
            == .missing)
}

@Test func correctionsRecordACaseEventAndAMemoryNote() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let correction = CaseCorrection(
        steward: PreviewFixtures.steward, casebook: PreviewFixtures.casebook,
        caseID: PreviewFixtures.failingCase, text: "  Timeouts are bugs.  ", expected: nil,
        rehearsal: PreviewFixtures.rehearsal, run: "run_r7")
    let written = try await workspace.record(.correctCase(correction))
    #expect(written.map(\.type) == ["case.corrected", "memory.added"])
    #expect(written.allSatisfy { $0.actor == .localUser && $0.steward == PreviewFixtures.steward })
    #expect(written[0].payload["text"]?.string == "Timeouts are bugs.")
    let all = await workspace.events()
    let result = try rehearsal(all).cases[1]
    #expect(result.corrections.map(\.text) == ["Timeouts are bugs."])
    let note = MemoryList.build(events: all).live[0]
    #expect(note.caseID == PreviewFixtures.failingCase)
    #expect(note.author == .localUser)
    var empty = correction
    empty.text = "   "
    await #expect(throws: FeatureWriteError.correctionEmpty) {
        try await workspace.record(.correctCase(empty))
    }
}

@Test func markReadyIsRecordedOncePerCharterVersion() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    let item = try rehearsal()
    #expect(RehearsalList.build(events: events).canMarkReady(item))
    let written = try await workspace.record(
        .markReady(steward: PreviewFixtures.steward, charterVersion: 1, rehearsal: item.id))
    #expect(written.map(\.type) == ["steward.ready"])
    #expect(written[0].actor == .localUser)
    let list = RehearsalList.build(events: await workspace.events())
    let mark = try #require(list.readyMark(steward: PreviewFixtures.steward, charterVersion: 1))
    #expect(mark.rehearsal == item.id)
    #expect(RehearsalsText.ready(mark, now: mark.at) == "Ready since just now, marked by local")
    #expect(list.canMarkReady(list.rehearsals[0]) == false)
}

@Test func proposalRehearsalsCannotMarkReady() {
    var log = FeatureEventBuilder(start: now)
    log.add("rehearsal.started", ["rehearsal": "rh_p", "charterVersion": 2, "proposal": "pr_1"])
    log.add("rehearsal.finished", ["rehearsal": "rh_p", "meanScore": 1, "passed": 1])
    let list = RehearsalList.build(events: log.events)
    #expect(list.canMarkReady(list.rehearsals[0]) == false)
    #expect(RehearsalsText.meta(list.rehearsals[0]).hasSuffix("for proposal pr_1"))
}
