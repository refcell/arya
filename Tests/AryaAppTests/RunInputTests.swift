import Foundation
import Testing

@testable import AryaApp

@Test func crewReportReadsAsChildSentencesWithTheParent() throws {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    log.add("run.started", run: "p1", ["input": ["kind": "message", "text": "Refund MSG-9"]])
    log.add("run.delegated", run: "p1", ["delegation": "draft", "title": "Draft", "child": "c1"])
    log.add("run.finished", run: "p1", ["status": "completed", "summary": "Proposed the refund."])
    let report = """
        {"children":[{"run":"c1","title":"Draft the reply","status":"completed",\
        "summary":"Drafted the reply for MSG-9.","actions":[{"kind":"reply"}]}]}
        """
    log.add(
        "run.started", run: "j1",
        ["trigger": "join", "input": ["kind": "join", "text": .string(report)]])
    let stream = RunStream.build(events: log.events, run: "j1")
    let reading = try #require(stream.reading)
    guard case .crew(let children) = reading.body else {
        Issue.record("expected a crew reading")
        return
    }
    #expect(
        children.first?.sentence == "Drafted the reply for MSG-9. 1 action proposed for approval.")
    #expect(children.first?.run == "c1")
    #expect(reading.parent?.title == "Proposed the refund.")
    #expect(
        RunThreadText.meta(stream).hasPrefix("checks the delegated work from Proposed the refund."))
    #expect(reading.raw?.contains("\n") == true)
}

@Test func structuredInputReadsAsOneLine() {
    let reading = RunInput.build(
        kind: "event", text: #"{"order":"O-1","reason":"late"}"#, events: [])
    #expect(reading.body == .structured("Structured input: 2 fields (order, reason)"))
    #expect(RunInput.build(kind: "message", text: "Where is it?", events: []).raw == nil)
}
