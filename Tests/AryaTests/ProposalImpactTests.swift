import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private func encoded(_ charter: Charter) throws -> Data { try JSONEncoder().encode(charter) }

@Test func proposalImpactNamesWhatALooserCharterRemoves() async throws {
    let opened = try await Opened([])
    let workspace = opened.workspace
    var live = try Charter.load(from: try inboxCharterJSON())
    live.guardrails = ["Never close a ticket without a reply."]
    _ = try await workspace.createSteward(charter: try encoded(live))

    var looser = live
    looser.outcome = live.outcome + " Faster."
    looser.metric.target = 0.5
    looser.guardrails.removeFirst()
    looser.policy.default = .auto
    looser.policy.rules = [Policy.Rule(action: "refund", decision: .auto)]
    looser.adapter = "other"
    let proposal = try await workspace.proposeCharter(
        steward: "st_inbox", charter: try encoded(looser), baseVersion: 1)
    #expect(proposal.impact == ["adapter", "guardrails", "metric", "outcome", "signoff"])
    #expect(proposal.removed.first == "guardrail removed: “\(live.guardrails[0])”")
    #expect(proposal.removed.contains("adapter \(live.adapter) → other"))
    #expect(proposal.removed.contains { $0.hasPrefix("actions without a rule go from") })
    let detail = try #require(proposal.detail)
    #expect(detail.needsConfirm)
    #expect(detail.ownsSentence?.hasPrefix("This changes what the steward owns: “") == true)
    #expect(detail.loosensSentence?.hasPrefix("Removes 1 guardrail: “") == true)

    // Reads agree, and keep the impact after the charter changes.
    #expect(try await workspace.proposal(proposal.id)?.impact == proposal.impact)
    var renamed = live
    renamed.name = "Renamed"
    let harmless = try await workspace.proposeCharter(
        steward: "st_inbox", charter: try encoded(renamed), baseVersion: 1)
    #expect(harmless.impact.isEmpty && harmless.removed.isEmpty)
    #expect(harmless.detail?.needsConfirm == false)

    // Once the charter moves on, a fresh workspace still measures against the base version.
    _ = try await StewardLifecycle(sink: await workspace.sink).updateCharter(renamed)
    let reopened = try await Workspace.open(home: opened.home.url)
    #expect(try await reopened.proposal(proposal.id)?.impact == proposal.impact)
}

@Test func proposalImpactRulesMatchTheApp() throws {
    var live = try Charter.load(from: try inboxCharterJSON())
    live.policy.default = .ask
    live.policy.rules = [
        Policy.Rule(action: "send", decision: .deny), Policy.Rule(action: "reply", decision: .ask),
    ]
    live.autonomy = .suggest
    var proposed = live
    proposed.policy.rules = [
        Policy.Rule(action: "send", decision: .ask), Policy.Rule(action: "reply", decision: .deny),
    ]
    proposed.autonomy = .actLow
    let impact = ProposalImpact(live: live, proposed: proposed)
    #expect(impact.kinds == ["signoff"])
    #expect(
        impact.loosened == [
            "send no longer blocked", "autonomy raised from suggest to act_low",
        ])
    #expect(!impact.changesOwnership)
    #expect(ProposalImpact(live: proposed, proposed: live).loosened == ["reply no longer blocked"])
}

@Test func proposalSummariesDecodeWithoutImpact() throws {
    let old = Data(
        (#"{"id":"prop_1","steward":"st_inbox","baseVersion":1,"candidateVersion":2,"#
            + #""author":"human:local","status":"open","acceptable":false}"#).utf8)
    let summary = try JSONDecoder().decode(ProposalSummary.self, from: old)
    #expect(summary.impact.isEmpty && summary.removed.isEmpty && summary.detail == nil)
    let again = try JSONDecoder().decode(
        ProposalSummary.self, from: try JSONEncoder().encode(summary))
    #expect(again == summary)
}
