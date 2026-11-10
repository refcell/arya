import Foundation
import Testing

@testable import AryaApp

private func item(_ id: String, kind: String = "assign") -> ApprovalItem {
    var item = ApprovalQueue.build(events: PreviewFixtures.triage(now: FeatureTestClock.now))
        .pending[0]
    item.id = id
    item.kind = kind
    return item
}

@Test func needsYouKeysMoveAndClamp() {
    let keys = NeedsYouKeys(pending: [item("a"), item("b"), item("c")], selected: "b")
    #expect(keys.current?.id == "b")
    #expect(keys.step(1) == "c")
    #expect(keys.step(-1) == "a")
    #expect(NeedsYouKeys(pending: [item("a"), item("b")], selected: "b").step(1) == "b")
    #expect(NeedsYouKeys(pending: [item("a")], selected: nil).current?.id == "a")
    #expect(NeedsYouKeys(pending: [], selected: nil).step(1) == nil)
}

@Test func needsYouLetterKeysMapToActions() {
    #expect(NeedsYouKeys.action(for: "j") == .next)
    #expect(NeedsYouKeys.action(for: "K") == .previous)
    #expect(NeedsYouKeys.action(for: "a") == .approve)
    #expect(NeedsYouKeys.action(for: "d") == .deny)
    #expect(NeedsYouKeys.action(for: "x") == nil)
}

@Test func highRiskApprovalsAskFirst() {
    #expect(NeedsYouKeys.needsConfirm(item("a", kind: "refund")))
    #expect(!NeedsYouKeys.needsConfirm(item("a", kind: "label")))
    #expect(!NeedsYouKeys.needsConfirm(item("a", kind: "question")))
}
