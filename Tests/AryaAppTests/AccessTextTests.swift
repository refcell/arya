import Arya
import Foundation
import Testing

@testable import Arya
@testable import AryaApp

/// Settings ▸ Access reads in words: names, not ids; refusals say what was refused and where;
/// each person's access counts their teams' grants.
@MainActor @Test func accessReadsInWordsWithTeamsCounted() {
    let overview = AccessSnapshotTests.fixture
    #expect(AccessText.words("crm") == "CRM")
    #expect(AccessText.words("support-desk") == "Support Desk")
    #expect(AccessText.refusal(overview.refusals[0], in: overview) == "Sam can't refund in Billing")
    #expect(
        AccessText.refusal(overview.refusals[1], in: overview)
            == "Sam can't approve reply for Support inbox triage")
    #expect(AccessText.effective("person:sam", in: overview) == "use Inbox")
    #expect(
        AccessText.effective("person:ana", in: overview).hasSuffix("approve Support inbox triage"))
    #expect(AccessText.effective("person:nobody", in: overview) == "No grants")
    #expect(AccessText.teams(of: "person:sam", in: overview) == ["Support"])
    #expect(AccessText.asked(overview.refusals[0]) == "“Refund order 7 in full” · ORD-7")
    #expect(AccessText.touches(overview.teams[0], in: overview) == "can use Inbox")
    let use = AccessText.use(overview.grants[0], now: AccessSnapshotTests.now)
    #expect(use.hasPrefix("Used 3× this week · last by Sam: label MSG-140 · "))
    #expect(AccessText.use(overview.grants[1], now: AccessSnapshotTests.now) == "Not used yet")
    #expect(AccessText.mostUsed(overview).map(\.seq) == [40])
    let refused = AccessText.refusedBy(overview, now: AccessSnapshotTests.now)
    #expect(refused.map(\.person) == ["person:sam"] && refused.first?.count == 2)
    #expect(refused.first?.what == "refund, reply")
}
