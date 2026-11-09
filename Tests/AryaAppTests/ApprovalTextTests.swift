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
