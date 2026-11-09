import Arya
import AryaDesign
import Foundation
import Testing

@testable import AryaApp

@Suite struct NavigationTests {
    @Test func tabsFollowTheStyleGuideOrder() {
        #expect(
            StewardTab.allCases.map(\.title) == ["Overview", "Improve", "Knowledge", "Ledger"])
        #expect(StewardTab.allCases.count <= 4)
    }

    @Test func selectingARunKeepsTheTab() {
        var state = NavigationState()
        #expect(state.tab == .overview)
        state.tab = .ledger
        state.select(run: "run_14", steward: "st_triage")
        #expect(state.steward == "st_triage")
        #expect(state.run == "run_14")
        #expect(state.tab == .ledger)
    }

    @Test func stewardsOpenOnTheirOverview() {
        #expect(NavigationState().tab == .overview)
    }

    @Test func switchingStewardsClearsTheRunAndOpensTheOverview() {
        var state = NavigationState()
        state.select(run: "run_14", steward: "st_triage")
        state.tab = .knowledge
        state.select(steward: "st_triage")
        #expect(state.run == "run_14")
        state.select(steward: "st_spend")
        #expect(state.run == nil)
        #expect(state.tab == .overview)
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

    @Test func threadsAreTitledBySummaryNeverById() {
        let at = Date(timeIntervalSince1970: 0)
        var run = RunSummary(
            id: "run_01M70W8CV2", steward: "st_triage", trigger: "manual", charterVersion: 1,
            status: .finished, summary: "billing · routed MSG-201\nmore", startedAt: at)
        #expect(StatusMapping.threadTitle(of: run) == "billing · routed MSG-201")
        run.summary = nil
        #expect(StatusMapping.threadTitle(of: run) == "manual run")
        #expect(!StatusMapping.threadTitle(of: run).contains("run_"))
    }

    @Test func thePrimaryActionNamesTheApprovals() {
        #expect(StewardPage.reviewTitle(1) == "Review 1 approval")
        #expect(StewardPage.reviewTitle(3) == "Review 3 approvals")
    }

    @Test func railWidthStaysInBounds() {
        #expect(RailWidth.clamp(100) == AryaSize.sidebarMinWidth)
        #expect(RailWidth.clamp(260) == 260)
        #expect(RailWidth.clamp(900) == AryaSize.sidebarMaxWidth)
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
