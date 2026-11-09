import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

@Test func ledgerRunsReadAsTheirTitle() {
    let events = PreviewFixtures.triage(now: now)
    let table = LedgerTable.build(events: events, filter: .all)
    let event = table.rows.first { $0.run == PreviewFixtures.finishedRun }!
    let label = LedgerText.runLabel(event, titles: table.runTitles)
    #expect(!label.hasPrefix("run_"))
    #expect(table.runTitles[PreviewFixtures.finishedRun] != nil)
    #expect(table.typeWidth == table.rows.map(\.type.count).max())
}

@Test func ledgerSearchMatchesTypeTitleAndPayload() {
    let events = PreviewFixtures.triage(now: now)
    var filter = LedgerFilter.all
    filter.query = "APPROVAL.REQ"
    let table = LedgerTable.build(events: events, filter: filter)
    #expect(!table.rows.isEmpty)
    #expect(
        table.rows.allSatisfy {
            $0.type == "approval.requested"
                || $0.payload.compactText.lowercased().contains("approval.req")
        })
    filter.query = "no such text anywhere"
    #expect(LedgerTable.build(events: events, filter: filter).rows.isEmpty)
    #expect(!filter.isFiltered)
}

@Test func ledgerColumnsPadToFixedWidths() {
    #expect(LedgerText.pad("12", 4, leading: true) == "  12")
    #expect(LedgerText.pad("run.started", 14) == "run.started   ")
    #expect(LedgerText.verifyStatus(.broken(seq: 41, reason: "hash")) == "chain broken at 41")
    #expect(LedgerText.verifyStatus(.intact(events: 3)) == "chain intact")
}
