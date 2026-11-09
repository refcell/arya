import Foundation
import Testing

@testable import AryaApp

@Suite struct NavigationTests {
    @Test func tabsFollowTheStyleGuideOrder() {
        #expect(
            StewardTab.allCases.map(\.title) == [
                "Stream", "Changes", "Ledger", "Memory", "Routines", "Rehearsals",
            ])
    }

    @Test func selectingARunShowsItsStream() {
        var state = NavigationState()
        state.tab = .ledger
        state.select(run: "run_14", steward: "st_triage")
        #expect(state.steward == "st_triage")
        #expect(state.run == "run_14")
        #expect(state.tab == .stream)
    }

    @Test func switchingStewardsClearsTheRunButKeepsTheTab() {
        var state = NavigationState()
        state.select(run: "run_14", steward: "st_triage")
        state.tab = .memory
        state.select(steward: "st_triage")
        #expect(state.run == "run_14")
        state.select(steward: "st_spend")
        #expect(state.run == nil)
        #expect(state.tab == .memory)
    }

    @Test func reconcileFallsBackToTheFirstSteward() {
        var state = NavigationState()
        state.reconcile(stewards: ["st_a", "st_b"], runs: [])
        #expect(state.steward == "st_a")
        state.select(run: "run_1", steward: "st_b")
        state.reconcile(stewards: ["st_a", "st_b"], runs: [])
        #expect(state.steward == "st_b" && state.run == nil)
        state.reconcile(stewards: ["st_a"], runs: [])
        #expect(state.steward == "st_a")
        state.reconcile(stewards: [], runs: [])
        #expect(state.destination == nil)
    }

    @Test func approvalsSurviveReconcile() {
        var state = NavigationState()
        state.showApprovals()
        state.reconcile(stewards: ["st_a"], runs: [])
        #expect(state.destination == .approvals)
    }

    @Test func runsAreNumberedInStartOrder() {
        #expect(StatusMapping.runLabel(position: 0, of: 14) == "run 14")
        #expect(StatusMapping.runLabel(position: 13, of: 14) == "run 1")
    }

    @Test func railWidthStaysInBounds() {
        #expect(RailWidth.clamp(100) == 200)
        #expect(RailWidth.clamp(260) == 260)
        #expect(RailWidth.clamp(900) == 320)
    }
}

@Suite struct HomeLocatorTests {
    let support = URL(fileURLWithPath: "/tmp/support", isDirectory: true)

    @Test func homeArgumentBeatsTheEnvironment() {
        let choice = HomeLocator.resolve(
            arguments: ["AryaApp", "--home", "/tmp/demo"], environment: ["ARYA_HOME": "/tmp/h"],
            applicationSupport: support)
        #expect(choice == .home(URL(fileURLWithPath: "/tmp/demo")))
    }

    @Test func textScaleSteps() {
        #expect(TextScale.bigger(1) == 1.15)
        #expect(TextScale.bigger(1.5) == 1.5)
        #expect(TextScale.smaller(1) == 0.85)
        #expect(TextScale.smaller(0.85) == 0.85)
        #expect(TextScale.normalized(1.1) == 1.15)
        #expect(TextScale.normalized(9) == 1.5)
    }

    @Test func aryaHomeThenDefault() {
        let set = HomeLocator.resolve(
            arguments: [], environment: ["ARYA_HOME": "/tmp/h"], applicationSupport: support)
        #expect(set == .home(URL(fileURLWithPath: "/tmp/h")))
        let fallback = HomeLocator.resolve(
            arguments: [], environment: [:], applicationSupport: support)
        #expect(fallback == .home(support.appendingPathComponent("arya", isDirectory: true)))
    }
}
