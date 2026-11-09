import Arya
import Foundation
import Testing

@testable import AryaApp

private let autonomyHold = """
    {"id":"ap_1","kind":"action","steward":"st_triage","run":"run_1","actionKind":"label",
     "target":"inbox:MSG-1","text":"label it","to":"local","status":"pending",
     "requestedAt":"2026-11-09T08:00:00Z","policyRule":"autonomy:suggest",
     "policyText":"This steward only suggests actions, so every action waits for you.",
     "change":{"field":"label","to":"billing","text":"label: none → billing"}}
    """

@Test func autonomyHoldsShowTheWorkspaceSentenceVerbatim() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(ApprovalSummary.self, from: Data(autonomyHold.utf8))
    let texts = Workspace.approvalTexts([summary])
    #expect(
        texts["ap_1"]?.policy
            == "This steward only suggests actions, so every action waits for you.")
    #expect(texts["ap_1"]?.change == "label: none → billing")
}

private struct TextsWorkspace: FeatureWorkspace {
    var log: [FeatureEvent]
    func events() async throws -> [FeatureEvent] { log }
    func record(_ write: FeatureWrite) async throws -> [FeatureEvent] { [] }
    func verify() async throws -> FeatureVerifyResult { .intact(events: log.count) }
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func approvalTexts() async throws -> [String: FeatureApprovalText] {
        ["ap_0001": FeatureApprovalText(policy: "Assignments need your sign-off.", change: nil)]
    }
}

@MainActor @Test func storeLoadsTheWorkspaceApprovalTexts() async {
    let now = FeatureTestClock.now
    let store = FeatureStore(
        workspace: TextsWorkspace(log: PreviewFixtures.triage(now: now)), now: now)
    await store.reload()
    #expect(store.approvalTexts["ap_0001"]?.policy == "Assignments need your sign-off.")
    let preview = FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now)
    await preview.reload()
    #expect(preview.approvalTexts.isEmpty)
    let canned = FeatureStore(
        workspace: PreviewWorkspace(
            events: [], now: now,
            approvalTexts: [
                "ap_9": FeatureApprovalText(policy: "Held.", change: "label: none → bug")
            ]),
        now: now)
    await canned.reload()
    #expect(canned.approvalTexts["ap_9"]?.change == "label: none → bug")
}

private func step(_ kind: String, target: String, _ params: FeatureJSON) -> ProposedActionStep {
    ProposedActionStep(
        actionID: "a1", kind: kind, target: target, summary: "", rationale: "", policy: "ask",
        outcome: .awaitingApproval(approval: "ap_1"), params: params)
}

@Test func structuredParamsReadAsOneSentence() {
    let refund = step(
        "refund", target: "shop:customer-7",
        ["amount": 24, "currency": "USD", "order": "ORDER-1043"])
    #expect(ActionSummary.sentence(refund) == "Refund 24.00 USD on ORDER-1043")
    let priority = step("set_priority", target: "inbox:MSG-9", ["level": "high", "notify": true])
    #expect(
        ActionSummary.sentence(priority) == "Set priority inbox:MSG-9 with level high, notify true")
    #expect(ActionSummary.sentence(step("archive", target: "inbox:MSG-9", [:])) == nil)
}

private struct DetailWorkspace: FeatureWorkspace {
    func events() async throws -> [FeatureEvent] { [] }
    func record(_ write: FeatureWrite) async throws -> [FeatureEvent] { [] }
    func verify() async throws -> FeatureVerifyResult { .intact(events: 0) }
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func eventDetail(seq: Int) async throws -> FeatureEventDetail? {
        FeatureEventDetail(payloadText: "{}", hash: "sha256:aa\(seq)", prev: "", step: nil)
    }
}

@MainActor @Test func inspectorChainValuesComeFromTheWorkspace() async {
    let store = FeatureStore(workspace: DetailWorkspace(), now: FeatureTestClock.now)
    await store.loadEventDetail(seq: 1)
    #expect(store.eventDetails[1]?.hash == "sha256:aa1")
    #expect(LedgerText.chainValue("", label: "Prev") == "none (first event)")
    #expect(LedgerText.chainValue("sha256:bb", label: "Hash") == "sha256:bb")
}
