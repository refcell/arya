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
