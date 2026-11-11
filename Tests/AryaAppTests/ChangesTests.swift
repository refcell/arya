import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let passing = PreviewFixtures.passingProposal
private let failing = PreviewFixtures.failingProposal

@Test func proposalsCarryGateResultsNewestFirst() throws {
    let list = ChangeList.build(events: PreviewFixtures.triage(now: now))
    #expect(list.open.map(\.id) == [failing, passing])
    #expect(list.closed.isEmpty)
    let routine = list.open[0]
    #expect(routine.kind == "routine")
    #expect(routine.canAccept == false)
    #expect(routine.canOverride)
    #expect(ChangesText.meta(routine) == "routine · from run_0001")
    #expect(ChangesText.gate(routine.gate) == "Score 0.80 against a baseline of 0.90.")
    #expect(ChangesText.regressions(routine.gate) == "Regressed: case-0003, case-0007")
    let charter = list.open[1]
    #expect(charter.canAccept)
    #expect(charter.canOverride == false)
    #expect(ChangesText.meta(charter) == "charter v2 · from local")
    #expect(ChangesText.regressions(charter.gate) == nil)
}

@Test func ungatedProposalsWaitForRehearsal() {
    var log = FeatureEventBuilder(start: now)
    log.add("proposal.created", ["id": "pr_x", "kind": "charter", "title": "Tighten tone"])
    let item = ChangeList.build(events: log.events).open[0]
    #expect(item.canAccept == false)
    #expect(item.canOverride == false)
    #expect(ChangesText.gate(item.gate) == "Rehearsing against the casebook.")
    let noBaseline = GateResult(
        passed: true, baselineMean: nil, candidateMean: 1, regressions: [], reason: "")
    #expect(ChangesText.gate(noBaseline) == "Score 1.00; no baseline yet.")
}

@Test func acceptRejectAndOverrideAreRecordedAndValidated() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    await #expect(throws: FeatureWriteError.gateNotPassed(failing)) {
        try await workspace.record(.acceptProposal(failing))
    }
    await #expect(throws: FeatureWriteError.gatePassed(passing)) {
        try await workspace.record(.overrideProposal(passing, reason: "x"))
    }
    let overridden = try await workspace.record(.overrideProposal(failing, reason: "worth it"))
    #expect(overridden.map(\.type) == ["proposal.overridden", "proposal.accepted"])
    #expect(overridden.allSatisfy { $0.actor == .localUser })
    try await workspace.record(.rejectProposal(passing, reason: "too broad"))
    await #expect(throws: FeatureWriteError.proposalClosed(passing)) {
        try await workspace.record(.acceptProposal(passing))
    }
    await #expect(throws: FeatureWriteError.unknownProposal("pr_nope")) {
        try await workspace.record(.rejectProposal("pr_nope", reason: ""))
    }
    let list = ChangeList.build(events: await workspace.events())
    #expect(list.open.isEmpty)
    #expect(
        list.closed.map { ChangesText.state($0.state) } == [
            "Accepted by you over a failed gate", "Rejected by you: too broad",
        ])
}

@Test func acceptingAPassingProposalClosesIt() async throws {
    let workspace = PreviewWorkspace.triage(now: now)
    try await workspace.record(.acceptProposal(passing))
    let list = ChangeList.build(events: await workspace.events())
    #expect(list.open.map(\.id) == [failing])
    #expect(list.closed.first?.state == .accepted(by: .localUser, overridden: false))
}

/// The shapes the ledger actually records (`ProposalCreatedPayload`, `ProposalGatedPayload`).
@Test func ledgerShapedProposalsShowWithTheirGate() {
    var log = FeatureEventBuilder(start: now)
    log.add(
        "proposal.created",
        [
            "proposal": "prop_1", "kind": "charter", "baseVersion": 1, "candidateVersion": 2,
            "reason": "Treat card questions as how-to\nThey are not billing.",
        ])
    log.add(
        "proposal.gated",
        [
            "proposal": "prop_1", "casebook": "cb_1",
            "verdict": [
                "passed": false, "baselineMean": 0.9583, "candidateMean": 0.9583,
                "regressions": ["case-0005"], "reason": "case regressed",
            ],
        ])
    let list = ChangeList.build(events: log.events)
    let item = list.open[0]
    #expect(list.open.map(\.id) == ["prop_1"])
    #expect(item.title == "Treat card questions as how-to")
    #expect(item.canOverride)
    #expect(ChangesText.regressions(item.gate) == "Regressed: case-0005")
}
