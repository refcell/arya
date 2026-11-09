import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now
private let old = "sha256:1a2b3c"
private let new = "sha256:4d5e6f"

private func routineRun(
    _ log: inout FeatureEventBuilder, run: String, approval: String, granted: Bool
) {
    let action: FeatureJSON = [
        "id": "a1", "kind": "routine", "target": "tracker:ISSUE-9",
        "params": ["name": "label-duplicates"], "rationale": "Same title as ISSUE-4.",
    ]
    log.add("run.started", run: run, ["trigger": "manual"])
    log.add("action.proposed", run: run, ["action": action, "disposition": "ask"])
    log.add(
        "approval.requested", run: run,
        ["approval": .string(approval), "kind": "action", "action": action, "to": "local"])
    if granted {
        log.add("approval.granted", run: run, actor: .localUser, ["approval": .string(approval)])
    }
}

private func promote(_ log: inout FeatureEventBuilder, _ version: String) {
    log.add("routine.proposed", ["v": 1, "name": "label-duplicates", "version": .string(version)])
    log.add("routine.promoted", ["v": 1, "name": "label-duplicates", "version": .string(version)])
}

private func history() -> [FeatureEvent] {
    var log = FeatureEventBuilder(start: now)
    promote(&log, old)
    routineRun(&log, run: "run_a", approval: "ap_a", granted: true)
    promote(&log, new)
    routineRun(&log, run: "run_b", approval: "ap_b", granted: false)
    return log.events
}

@Test func subjectIsTheLiveVersionAtRunStartAndTheLastApprovedOne() throws {
    let events = history()
    let first = try #require(RoutineApprovalSubject.find(events: events, approval: "ap_a"))
    #expect(first.version == old)
    #expect(first.previousApproved == nil)
    #expect(
        RoutineApprovalText.title(first) == "Routine label-duplicates 1a2b3c, never approved before"
    )
    let second = try #require(RoutineApprovalSubject.find(events: events, approval: "ap_b"))
    #expect(second.version == new)
    #expect(second.previousApproved == old)
    #expect(
        RoutineApprovalText.title(second)
            == "Routine label-duplicates 4d5e6f, changed since approved 1a2b3c")
    let triage = PreviewFixtures.triage(now: now)
    #expect(
        RoutineApprovalSubject.find(events: triage, approval: PreviewFixtures.pendingApproval)
            == nil)
}

@Test func loaderReturnsBodyAndDiffFromTheApprovedVersion() async throws {
    let events = history()
    let subject = try #require(RoutineApprovalSubject.find(events: events, approval: "ap_b"))
    let workspace = PreviewWorkspace(
        events: events, now: now, routines: [old: "echo one\n", new: "echo one\necho two\n"])
    let state = await RoutineApprovalLoader.load(workspace, subject)
    guard case .loaded(let body, let diff) = state else {
        Issue.record("expected a loaded routine, got \(state)")
        return
    }
    #expect(body == "echo one\necho two\n")
    #expect(diff?.contains("+echo two") == true)
    let missing = await RoutineApprovalLoader.load(
        PreviewWorkspace(events: events, now: now), subject)
    #expect(missing == .failed("The body of 4d5e6f is missing."))
}

@Test func alwaysAllowProposesTheVersionRule() async throws {
    var log = FeatureEventBuilder(start: now)
    log.add(
        "steward.created", actor: .localUser, ["charter": PreviewFixtures.charter, "version": 1])
    let events = log.events + history()
    let subject = try #require(RoutineApprovalSubject.find(events: events, approval: "ap_b"))
    let proposal = try #require(RoutineAllowance.proposal(events: events, subject: subject))
    #expect(proposal.baseVersion == 1)
    #expect(proposal.title == "Allow routine label-duplicates 4d5e6f")
    let rules = proposal.charter["policy"]?["rules"]?.array ?? []
    #expect(rules.last == ["action": "routine:label-duplicates@sha256:4d5e6f", "decision": "auto"])
    #expect(CharterDraft(charter: proposal.charter).issues.isEmpty)
    let workspace = PreviewWorkspace(events: events, now: now)
    let written = try await workspace.record(.proposeCharter(proposal))
    #expect(written.map(\.type) == ["proposal.created"])
    var later = FeatureEventBuilder(start: now)
    later.add(
        "steward.charter.updated", actor: .localUser,
        ["charter": proposal.charter, "version": 2])
    let allowed = later.events[0]
    #expect(RoutineAllowance.proposal(events: events + [allowed], subject: subject) == nil)
    #expect(RoutineAllowance.proposal(events: history(), subject: subject) == nil)
}
