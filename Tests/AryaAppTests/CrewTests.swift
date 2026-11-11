import Foundation
import Testing

@testable import AryaApp

private let events = PreviewFixtures.crew(now: FeatureTestClock.now)

private func delegations() -> [DelegationStep] {
    RunStream.build(events: events, run: PreviewFixtures.crewRun).steps.compactMap {
        if case .delegated(let step) = $0.kind { return step }
        return nil
    }
}

@Test func delegationsBecomeOneStepWithTheChildInside() throws {
    let steps = delegations()
    #expect(steps.count == 2)
    let child = try #require(steps.first)
    #expect(CrewText.line(child) == "drafted the refund reply · child run · 2.1 s")
    #expect(child.childSteps.count == 3)
    #expect(
        CrewText.budget(child) == "budget: adapter Fake · effort low · 4 turns · 60 s · $0.20")
    #expect(
        CrewText.result(child) == "Drafted a reply offering a refund for the second charge.")
}

@Test func refusedDelegationsSayWhy() throws {
    let refused = try #require(delegations().last)
    #expect(
        CrewText.line(refused)
            == "checked the order history · refused: not allowed to use this tool (browser)")
    #expect(refused.childSteps.isEmpty)
}

@Test func childEventsStayOutOfTheParentThread() {
    let parent = RunStream.build(events: events, run: PreviewFixtures.crewRun)
    #expect(parent.steps.count == 5)
    #expect(parent.title == "Labeled MSG-301 as billing with a drafted reply.")
}
