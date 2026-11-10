import Arya
import Foundation
import Testing

@testable import AryaApp

@Test func inspectorFollowsTheSelection() {
    var navigation = NavigationState()
    #expect(navigation.inspector)
    #expect(InspectorFocus.of(navigation) == .none)
    navigation.select(steward: "st_triage")
    #expect(InspectorFocus.of(navigation) == .steward("st_triage"))
    navigation.select(run: "run_0001", steward: "st_triage")
    #expect(InspectorFocus.of(navigation) == .run("run_0001"))
    navigation.select(steward: "st_triage", showRun: nil)
    navigation.tab = .ledger
    navigation.ledgerEvent = "ev_4"
    #expect(InspectorFocus.of(navigation) == .event("ev_4"))
    navigation.tab = .overview
    #expect(InspectorFocus.of(navigation) == .steward("st_triage"))
    navigation.showApprovals()
    #expect(InspectorFocus.of(navigation) == .approval(nil))
    navigation.approval = "ap_2"
    #expect(InspectorFocus.of(navigation) == .approval("ap_2"))
}

@Test func stewardContextListsConnectionsAndPeople() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var log = FeatureEventBuilder(start: start)
    let charter: FeatureJSON = [
        "outcome": "Sorted queue",
        "bindings": [["id": "inbox", "kind": "mcp", "read": ["messages"], "actions": ["label"]]],
    ]
    log.add("steward.created", steward: "st_triage", ["charter": charter])
    log.add("approval.granted", steward: "st_triage", actor: .localUser)
    log.add("approval.granted", steward: "st_triage", actor: .localUser)
    log.add("case.corrected", steward: "st_triage", actor: FeatureActor(kind: .human, id: "dana"))
    let context = StewardContext.build(events: log.events, steward: "st_triage", now: start)
    #expect(context.connections == ["inbox · mcp · read, actions"])
    #expect(context.people == ["local · 2 actions", "dana · 1 action"])
    #expect(context.state != nil)
}

@Test func runFactsReadDurationAndCost() {
    #expect(RunFacts.duration(0.2) == "0.2 s")
    #expect(RunFacts.duration(42) == "42 s")
    #expect(RunFacts.duration(185) == "3m 05s")
    #expect(RunFacts.duration(4320) == "1h 12m")
    #expect(RunFacts.cost(0) == "$0")
    #expect(RunFacts.cost(42_000) == "$0.042")
    #expect(RunFacts.cost(2_500_000) == "$2.50")
}

@Test func runFactsPluralizeAndHideUnknowns() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let run = RunSummary(
        id: "run_1", steward: "st_triage", trigger: "manual", charterVersion: 1,
        status: .finished, startedAt: start, endedAt: start, actionsProposed: 1)
    var log = FeatureEventBuilder(start: start)
    log.add("run.decision", steward: "st_triage", run: "run_1")
    let facts = Dictionary(
        RunFacts.lines(run, events: log.events, now: start), uniquingKeysWith: { a, _ in a })
    #expect(facts["Steps"] == "1 event · 1 decision · 0 tools")
    #expect(facts["Proposed"] == "1 action")
    #expect(facts["Duration"] == "—")
    #expect(facts["Cost"] == "—")
}

@Test func portfolioRowsSortByNeedAndReadTheFleet() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    func steward(_ id: String, _ name: String, _ status: StewardSummary.Status) -> StewardSummary {
        StewardSummary(
            id: id, name: name, outcome: "An outcome", charterVersion: 1, status: status,
            ready: true)
    }
    let rows = PortfolioRow.build(
        stewards: [steward("st_d", "Digest", .paused), steward("st_t", "Triage", .active)],
        runs: [:], approvals: [], events: [], now: now)
    #expect(rows.map(\.name) == ["Triage", "Digest"])
    #expect(rows[1].nextWake == "paused" && rows[1].state == "paused")
    #expect(rows[0].metric == "no metric" && rows[0].lastRun == "never")
    var navigation = NavigationState()
    navigation.showPortfolio()
    navigation.reconcile(stewards: ["st_t"], runs: [])
    #expect(navigation.destination == .portfolio)
    #expect(InspectorFocus.of(navigation) == .fleet)
}
