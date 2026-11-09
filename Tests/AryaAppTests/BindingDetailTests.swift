import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

@Test func proxiedToolCallsShowTheirBindingAndSource() throws {
    var log = FeatureEventBuilder(start: now)
    log.add("run.started", run: "run_x", ["trigger": "manual"])
    log.add(
        "run.tool.call", run: "run_x",
        ["id": "c1", "binding": "tracker", "tool": "search", "input": ["query": "is:open"]])
    log.add(
        "run.tool.result", run: "run_x", after: 2,
        ["id": "c1", "output": [], "isError": false, "source": "live"])
    log.add(
        "run.tool.call", run: "run_x",
        ["id": "c2", "binding": "tracker", "tool": "get", "input": ["id": "ISSUE-9"]])
    log.add(
        "run.tool.result", run: "run_x", after: 1,
        ["id": "c2", "output": "", "isError": true, "source": "unanswered"])
    log.add("run.tool.call", run: "run_x", ["id": "c3", "binding": "tracker", "tool": "get"])
    let calls = RunStream.build(events: log.events, run: "run_x").steps.compactMap { step in
        if case .toolCall(let call) = step.kind { return call } else { return nil }
    }
    #expect(calls.map(\.binding) == ["tracker", "tracker", "tracker"])
    #expect(
        calls.map(StreamStepText.toolCaption) == [
            "tracker · live · ok · \(FeatureTime.duration(2))",
            "tracker · no recording, a leak · failed · \(FeatureTime.duration(1))",
            "tracker · running",
        ])
}

@Test func actionsNameTheBindingTheyGoThrough() throws {
    let stream = RunStream.build(
        events: PreviewFixtures.triage(now: now), run: PreviewFixtures.finishedRun)
    let actions = stream.steps.compactMap { step in
        if case .action(let action) = step.kind { return action } else { return nil }
    }
    let label = try #require(actions.first)
    #expect(label.binding == "tracker")
    #expect(StreamStepText.actionCaption(label).hasPrefix("via tracker · "))
    var bare = label
    bare.binding = nil
    #expect(StreamStepText.actionCaption(bare) == StreamStepText.outcome(label.outcome))
}
