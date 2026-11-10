import AryaAdapters
import AryaCore
import AryaLedger
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

/// Support may label through the tracker; ana leads support and approves for the steward.
private let grants = AccessGrants(
    grants: [
        AccessGrant(subject: "team:support", level: .use, resource: "tool:tracker.label"),
        AccessGrant(subject: "person:ana", level: .approve, resource: "steward:st_triage"),
    ],
    teams: ["team:support": ["person:sam", "ana"]])

private func harness(_ runs: Int = 1, grants: AccessGrants? = grants) -> RunHarness {
    RunHarness(
        script: FakeScript(
            runs: Array(repeating: FakeScript.Run(result: triageResult), count: runs)),
        access: { _ in grants })
}

private func runAs(_ person: String, _ harness: RunHarness) async throws -> RunOutcome {
    try await harness.loop.run(
        RunRequest(
            steward: triage, input: RunInput(kind: .manual, text: "Triage ISSUE-7"),
            actor: .person(person)))
}

@Test func anActionWithoutAUseGrantIsRefusedRecordedAndRaised() async throws {
    let harness = harness(2)
    try await harness.lifecycle.create(triageCharter())
    let outcome = try await runAs("sam", harness)

    // sam's team may label; nobody granted comment, so it is refused, not asked.
    #expect(outcome.disposals.map(\.verdict.disposition) == [.auto, .deny])
    #expect(outcome.disposals[1].verdict.reason == Access.useReason)
    #expect(await harness.executor.requests.map(\.action.id) == ["a1"])
    let events = try await harness.sink.events(from: 1)
    let rejected = try #require(events.first { $0.type == "action.rejected" })
    #expect(rejected.payload["reason"] == "access:use")
    #expect(!events.contains { $0.type == "approval.requested" })
    let finding = try #require(events.first { $0.type == "finding.raised" })
    let raised = try Payload.decode(FindingRaised.self, finding.payload)
    #expect(raised.title == "Access refused: person:sam has no use grant for comment on tracker")
    #expect(raised.kind == "problem" && raised.needsPerson)

    // The same refusal again keeps one open finding.
    _ = try await runAs("sam", harness)
    let findings = try await harness.sink.events(from: 1).filter { $0.type == "finding.raised" }
    #expect(findings.count == 1)
}

@Test func theOwnerAndHomesWithoutGrantsAreNotLimited() async throws {
    let owner = harness()
    try await owner.lifecycle.create(triageCharter())
    let mine = try await owner.loop.run(.manual(triage, text: "Triage ISSUE-7"))
    #expect(mine.disposals.map(\.verdict.disposition) == [.auto, .ask])

    let open = harness(grants: nil)
    try await open.lifecycle.create(triageCharter())
    let theirs = try await runAs("sam", open)
    #expect(theirs.disposals.map(\.verdict.disposition) == [.auto, .ask])
}

@Test func aMessageActsOnBehalfOfItsSender() {
    let message = RunRequest(
        steward: triage,
        input: RunInput(kind: .message, text: "hi", attachments: [["from": "lena"]]),
        actor: .system)
    #expect(Access.principal(of: message) == "person:lena")
    #expect(Access.principal(of: .manual(triage, text: "x")) == nil)
    let fromOwner = RunRequest(
        steward: triage,
        input: RunInput(kind: .message, text: "hi", attachments: [["from": "local"]]),
        actor: .system)
    #expect(Access.principal(of: fromOwner) == nil)
    #expect(grants.grant(.use, person: "sam", on: ["tool:tracker.label"]) != nil)
    #expect(grants.grant(.use, person: "lena", on: ["tool:tracker.label"]) == nil)
}

@Test func decidingAnApprovalNeedsAnApproveGrant() async throws {
    let harness = harness()
    try await harness.lifecycle.create(triageCharter())
    let outcome = try await harness.loop.run(.manual(triage, text: "Triage ISSUE-7"))
    let approval = try #require(outcome.disposals[1].approval)

    await #expect(throws: ApprovalError.self) {
        try await harness.approvals.grant(approval, by: .person("sam"))
    }
    let refused = try #require(
        try await harness.sink.events(from: 1).first { $0.type == "approval.refused" })
    let body = try Payload.decode(ApprovalRefused.self, refused.payload)
    #expect(body.by == "sam" && body.rule == Access.approveRule && body.people == ["person:ana"])
    #expect(try await harness.approvals.book().records[approval]?.status == .pending)

    let granted = try await harness.approvals.grant(approval, by: .person("ana"))
    #expect(granted.status == .granted)
}
