import Foundation
import Testing

@testable import AryaApp

@Test func workPaneHasABlockPerToolCallAndActionWithDiffsLogAndOutput() {
    let now = FeatureTestClock.now
    let events = PreviewFixtures.triage(now: now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.finishedRun)
    let work = RunWork.build(stream: stream, events: events)
    let workSteps = stream.steps.filter { RunWork.isWork($0.kind) }.map(\.id)
    #expect(work.blocks.map(\.id) == workSteps)
    #expect(!work.blocks.isEmpty)
    #expect(
        work.diffs.count
            >= stream.steps.filter {
                if case .action = $0.kind { return true }
                return false
            }.count)
    #expect(
        work.log.count
            == events.filter {
                $0.run == stream.run && $0.type != "run.adapter.event"
            }.count)
    #expect(work.count(.tools) == work.blocks.count)
}

@Test func actionDiffsAddWhatTheActionWrites() throws {
    let step = StreamStep(
        id: "e1", number: 1, at: FeatureTestClock.now,
        kind: .action(
            ProposedActionStep(
                actionID: "a1", kind: "reply", target: "inbox:MSG-1", summary: "", rationale: "",
                policy: "ask", outcome: .proposed,
                params: ["text": .string("Line one\nLine two")])))
    let diff = try #require(RunWork.actionDiff(step))
    #expect(diff.text.hasPrefix("--- MSG-1\n+++ MSG-1\n@@ reply @@"))
    #expect(diff.added == 3)
    #expect(diff.countText == "+3 −0")
}

@Test func outputLinesShowDirectionMethodAndOneLineJSON() {
    let event = FeatureEvent(
        seq: 1, id: "e1", at: FeatureTestClock.now, steward: "s", run: "r", actor: .localUser,
        type: "run.adapter.event",
        payload: ["direction": "sent", "message": ["method": "initialize", "params": ["v": 1]]])
    let line = RunWork.outputLine(event, timeZone: TimeZone(identifier: "UTC")!)
    #expect(line.tag == "→ initialize")
    #expect(line.text == #"{"v":1}"#)
    #expect(line.tone == WorkLine.Tone.sent)
}

@Test func actionSentencesAndDiffsUseTheActualValues() {
    let label = ProposedActionStep(
        actionID: "a1", kind: "label", target: "tracker:ISSUE-7", summary: "", rationale: "",
        policy: "auto", outcome: .proposed, params: ["label": "bug"])
    let assign = ProposedActionStep(
        actionID: "a2", kind: "assign", target: "tracker:ISSUE-7", summary: "", rationale: "",
        policy: "ask", outcome: .proposed, params: ["to": "person:alex"])
    #expect(ActionSummary.sentence(label) == "Label ISSUE-7 as bug")
    #expect(ActionSummary.sentence(assign) == "Assign ISSUE-7 to Alex")
    let step = StreamStep(id: "e", number: 1, at: FeatureTestClock.now, kind: .action(label))
    #expect(RunWork.actionDiff(step)?.text.hasSuffix("\n+bug") == true)
}

@Test func dryRunRepliesReadAsDraftedNotSent() {
    var reply = ProposedActionStep(
        actionID: "a1", kind: "reply", target: "inbox:MSG-1", summary: "", rationale: "",
        policy: "ask", outcome: .executed(output: ""))
    reply.dryRun = true
    #expect(ActionWords.done(reply) == "drafted, not sent (dry run)")
    reply.dryRun = false
    #expect(ActionWords.done(reply) == "sent")
    #expect(RunWork.oneLine(["body": "a\nb"], limit: 100) == "{\"body\":\"a\nb\"}")
}

@Test func shortValuesStayOnOneLineInTheToolsPane() {
    #expect(RunWork.blockText(["query": "200-seat team"]) == #"{"query":"200-seat team"}"#)
    #expect(RunWork.blockText(.string("plain text")) == "plain text")
    let long = FeatureJSON.object(["text": .string(String(repeating: "a", count: 80))])
    #expect(RunWork.blockText(long).contains("\n"))
}

@Test func outputLeavesOutTheHandshakeAndKeepsTheLatestLines() {
    func event(_ seq: Int, _ direction: String, _ message: FeatureJSON) -> FeatureEvent {
        FeatureEvent(
            seq: seq, id: "e\(seq)", at: FeatureTestClock.now, steward: "s", run: "r",
            actor: .localUser, type: "run.adapter.event",
            payload: ["direction": .string(direction), "message": message])
    }
    var events = [
        event(1, "sent", ["id": 1, "method": "initialize", "params": ["v": 1]]),
        event(2, "received", ["id": 1, "result": ["capabilities": ["tools": true]]]),
        event(3, "sent", ["id": 2, "method": "run/start", "params": ["input": "x"]]),
        event(4, "received", ["id": 2, "result": ["ok": true]]),
        event(45, "sent", ["id": 3, "method": "run/cost", "params": ["session": "x"]]),
        event(46, "received", ["id": 3, "result": ["costMicros": 40650]]),
    ]
    for n in 0..<40 {
        events.append(
            event(
                5 + n, "received",
                [
                    "method": "run/event",
                    "params": ["event": ["kind": "tool_call", "tool": .string("crm.get \(n)")]],
                ]))
    }
    let lines = RunWork.outputLines(events, timeZone: TimeZone(identifier: "UTC")!)
    #expect(lines.count == 40)
    #expect(!lines.contains { $0.tag.contains("initialize") || $0.tag.contains("run/start") })
    #expect(!lines.contains { $0.text.contains("capabilities") || $0.text.contains("ok") })
    #expect(!lines.contains { $0.tag.contains("run/cost") || $0.text.contains("costMicros") })
    let tail = lines.suffix(WorkPane.logTail)
    #expect(tail.first?.text == "crm.get 10")
    #expect(tail.last?.text == "crm.get 39")
}
