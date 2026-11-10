import Arya
import Foundation
import Testing

@testable import AryaApp

@Test func paletteSearchMatchesInOrderAndRanksPrefixesFirst() {
    #expect(PaletteSearch.score("Toggle inspector", query: "tgi") != nil)
    #expect(PaletteSearch.score("Toggle inspector", query: "zz") == nil)
    #expect(PaletteSearch.score("Refresh", query: "") == 0)
    let make = { (title: String) in
        PaletteCommand(id: title, title: title, group: "Go") { _ in }
    }
    let commands = ["Show Ledger", "Go to Needs you", "Go to Support inbox triage"].map(make)
    #expect(PaletteSearch.filter(commands, query: "go").map(\.title).first == "Go to Needs you")
    #expect(PaletteSearch.filter(commands, query: "ledg").map(\.title) == ["Show Ledger"])
    #expect(
        PaletteSearch.filter(commands, query: "triage").map(\.title)
            == ["Go to Support inbox triage"])
}

@MainActor @Test func paletteOffersStewardActionsAndNavigation() async {
    let model = AppModel(source: FakeWorkspaceSource())
    await model.refresh()
    model.navigation.select(steward: "st_triage")
    let ids = CommandCatalog.all(model).map(\.id)
    for id in [
        "run-now", "pause", "edit-charter", "new-steward", "needs-you", "tab-ledger",
        "steward-st_spend", "sidebar", "inspector",
    ] {
        #expect(ids.contains(id), "missing \(id)")
    }
    let toggle = CommandCatalog.all(model).first { $0.id == "inspector" }
    toggle?.perform(model)
    #expect(!model.navigation.inspector)
    CommandCatalog.all(model).first { $0.id == "tab-ledger" }?.perform(model)
    #expect(model.navigation.tab == .ledger)
}

@Test func statusLineSummarizesTheFleet() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func steward(_ id: String, _ status: StewardSummary.Status) -> StewardSummary {
        StewardSummary(
            id: id, name: id, outcome: "An outcome", charterVersion: 1, status: status, ready: true)
    }
    let run = RunSummary(
        id: "run_1", steward: "a", parent: nil, trigger: "manual", charterVersion: 1,
        status: .finished, endStatus: nil, failureReason: nil, summary: nil,
        startedAt: now.addingTimeInterval(-60), endedAt: now, costMicros: 420_000,
        actionsProposed: 0)
    let line = StatusBarLine.build(
        stewards: [steward("a", .active), steward("b", .paused)], runs: ["a": [run]],
        waiting: 2, events: [],
        check: LedgerCheck(ok: true, events: 1755, firstBadSeq: nil, detail: nil), now: now,
        timeZone: utc)
    #expect(line.stewards == "2 stewards · 1 paused")
    #expect(line.ledger == "✓ verified 1755")
    #expect(line.cost == "$0.42 today")
    #expect(line.schedule == "no scheduled runs")
    #expect(line.waiting == 2)
}

@Test func schedulerCellReadsServeState() {
    #expect(StatusBarLine.scheduler(reason: "scheduler") == "scheduler")
    #expect(StatusBarLine.scheduler(reason: "runs") == "serving · runs")
    #expect(StatusBarLine.scheduler(reason: "off") == "stopped")
    #expect(StatusBarLine.scheduler(reason: nil) == "scheduler —")
}

@MainActor @Test func paletteShowsShortcutsAndActsOnTheSelectedApproval() async {
    let model = AppModel(source: FakeWorkspaceSource())
    await model.refresh()
    model.navigation.select(steward: "st_triage")
    let keys = Dictionary(
        CommandCatalog.all(model).map { ($0.id, $0.keys) }, uniquingKeysWith: { a, _ in a })
    #expect(keys["pause"] == "⌥⌘P")
    #expect(keys["rehearse"] == "⌥⌘T")
    let first = model.stewards.first?.id ?? ""
    #expect(keys["steward-\(first)"] == "⌃1")
    #expect(keys["sidebar"] == "⌘\\")
    model.navigation.showApprovals()
    let ids = CommandCatalog.all(model).map(\.id)
    #expect(ids.contains("deny-selected"))
}
