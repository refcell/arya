import Foundation
import Testing

@testable import AryaApp

@Test func runHeaderNamesAdapterDurationTokensAndCost() {
    let facts = RunMetrics(
        adapter: "fake-triage", effort: "medium", seconds: 2.4, tokens: 12_840, costMicros: 1_200)
    #expect(facts.text == "Triage (test) · effort medium · 2.4 s · 12,840 tokens · $0.0012")
    #expect(RunMetrics().text == "duration — · cost —")
    #expect(RunMetrics.count(1, "decision") == "1 decision")
    #expect(RunMetrics.count(4, "tool") == "4 tools")
    #expect(RunMetrics.dollars(250_000) == "$0.25")
}

@Test func finishedRunsCarryTheirFacts() {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    log.add("run.started", run: "r1", ["adapter": "fake", "effort": "low"])
    log.add(
        "run.finished", run: "r1", after: 3,
        [
            "status": "completed", "counts": ["decisions": 1, "actions": 3],
            "cost": ["costMicros": 0, "inputTokens": 100, "outputTokens": 20],
        ])
    let facts = RunStream.build(events: log.events, run: "r1").facts
    let expected =
        "Fake · effort low · 3.0 s · 1 decision · 3 actions · 120 tokens" + " · cost —"
    #expect(facts.text == expected)
}

@Test func toolAndActionLinesShowArgumentAndShortResult() {
    #expect(RunThreadText.argument(["id": "MSG-202"]) == "MSG-202")
    #expect(RunThreadText.arrow(["label": "billing"]) == "billing")
    #expect(RunThreadText.arrow(["a": 1, "b": 2]) == nil)
    #expect(RunThreadText.arrow(.string(String(repeating: "x", count: 50))) == nil)
}

@Test func longMachineOutputFoldsAfterFourLines() {
    #expect(MachineText.foldedLines == 4)
    #expect(MachineText.hidden(38) == "· 38 lines hidden")
}

@MainActor @Test func composerMessagesReachTheInbox() async {
    let now = FeatureTestClock.now
    let store = FeatureStore(workspace: PreviewWorkspace.triage(now: now), now: now)
    await store.reload()
    #expect(
        await store.perform(
            .message(steward: PreviewFixtures.steward, text: "Why billing?", intent: .ask)))
    guard case .loaded(let events) = store.state else { return }
    #expect(events.last?.type == "inbox.message")
    #expect(events.last?.payload["intent"]?.string == "ask")
    #expect(ComposerText.placeholder == "Ask, correct, or hand off…")
}
