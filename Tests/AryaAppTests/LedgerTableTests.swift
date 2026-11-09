import Foundation
import Testing

@testable import AryaApp

private let events = PreviewFixtures.triage(now: FeatureTestClock.now)

@Test func unfilteredTableIsNewestFirstWithFacets() {
    let table = LedgerTable.build(events: events, filter: .all)
    #expect(table.rows.count == events.count)
    #expect(table.rows.first?.seq == events.count)
    #expect(table.stewards == ["st_triage"])
    #expect(table.runs == ["run_0001", "run_0002", "run_r3", "run_r7"])
    #expect(table.namespaces == Array(Set(events.map(LedgerTable.namespace))).sorted())
    #expect(table.namespaces.contains("approval."))
    #expect(table.actors.contains("human:local"))
    #expect(LedgerText.count(table) == "\(events.count) events")
}

@Test func filtersCombine() {
    var filter = LedgerFilter(run: PreviewFixtures.finishedRun, type: "action.")
    var table = LedgerTable.build(events: events, filter: filter)
    #expect(table.rows.map(\.type) == ["action.proposed", "action.executed", "action.proposed"])
    #expect(LedgerText.count(table) == "3 matching")
    filter.type = "action.executed"
    table = LedgerTable.build(events: events, filter: filter)
    #expect(table.rows.count == 1)
    filter = LedgerFilter(actor: "human:local")
    table = LedgerTable.build(events: events, filter: filter)
    #expect(table.rows.allSatisfy { $0.actor == .localUser })
    #expect(table.rows.last?.type == "steward.created")
    #expect(filter.isActive)
    #expect(LedgerFilter.all.isActive == false)
}

@Test func runFacetFollowsTheStewardFilter() {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    log.add("run.started", steward: "st_a", run: "run_a")
    log.add("run.started", steward: "st_b", run: "run_b")
    let table = LedgerTable.build(events: log.events, filter: LedgerFilter(steward: "st_b"))
    #expect(table.runs == ["run_b"])
    #expect(table.stewards == ["st_a", "st_b"])
}

@Test func detailListsTheEnvelope() {
    let detail = LedgerText.detail(events[0])
    #expect(detail.map(\.label) == ["seq", "id", "at", "type", "steward", "run", "actor", "hash"])
    #expect(detail[4].value == "st_triage")
    #expect(detail[5].value == "—")
    #expect(detail[6].value == "human:local")
}

@Test func verifyTextStatesResultAndNextStep() {
    #expect(LedgerText.verify(.intact(events: 3)).hasPrefix("The ledger is intact: 3 events"))
    let broken = LedgerText.verify(.broken(seq: 7, reason: "hash mismatch"))
    #expect(broken.contains("event 7: hash mismatch"))
    #expect(broken.contains("read-only"))
}

@MainActor
@Test func storeVerifiesThroughTheWorkspace() async {
    let workspace = PreviewWorkspace.triage(now: FeatureTestClock.now)
    let store = FeatureStore(workspace: workspace, now: FeatureTestClock.now)
    #expect(store.verifyResult == nil)
    await store.verify()
    #expect(store.verifyResult == .intact(events: events.count))
    await workspace.simulateBreak(seq: 4, reason: "hash mismatch")
    await store.verify()
    #expect(store.verifyResult == .broken(seq: 4, reason: "hash mismatch"))
    #expect(store.isVerifying == false)
}

@Test func aStewardScopeSaysWhatItLeavesOut() {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    log.add("run.started", steward: "st_a", run: "run_a")
    log.add("run.started", steward: "st_b", run: "run_b")
    log.add("run.finished", steward: "st_b", run: "run_b")
    let table = LedgerTable.build(events: log.events, filter: LedgerFilter(steward: "st_b"))
    #expect(LedgerText.count(table) == "2 events for this steward")
    #expect(
        LedgerText.outOfScope(table)
            == "1 more event belongs to other stewards or the system")
    let all = LedgerTable.build(events: log.events, filter: .all)
    #expect(LedgerText.outOfScope(all) == nil)
    let verified = LedgerText.verifyStatus(.intact(events: 3), total: 3)
    #expect(verified == "✓ chain verified · 3 events")
}

@Test func allEventsNameStewardsFromTheirCharters() {
    let table = LedgerTable.build(events: events, filter: .all)
    #expect(table.stewardNames[PreviewFixtures.steward] == "Issue triage")
    #expect(LedgerText.count(table) == "\(events.count) events")
}
