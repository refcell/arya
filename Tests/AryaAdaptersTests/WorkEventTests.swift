import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// Work events survive the wire and read back typed; other kinds never look like them.
@Test func workEventsRoundTripAndReadTyped() throws {
    let events: [RunEvent] = [
        .output(.init(id: "t1", stream: "stderr", text: "denied\n")),
        .diff(.init(path: "r.sh", patch: "--- a/r.sh\n+++ b/r.sh\n@@ -1 +1 @@\n-a\n+b\n+c\n")),
        .progress(.init(done: 2, total: 4, label: "check the order")),
    ]
    let decoded = try events.map {
        try JSONDecoder().decode(RunEvent.self, from: JSONEncoder().encode($0))
    }
    #expect(decoded == events)
    #expect(decoded[0].outputChunk == .init(id: "t1", stream: "stderr", text: "denied\n"))
    let diff = try #require(decoded[1].fileDiff)
    #expect(diff.counts.added == 2 && diff.counts.removed == 1)
    #expect(decoded[2].progress == .init(done: 2, total: 4, label: "check the order"))
    let plain = RunEvent(.message(role: "assistant", text: "hi"))
    #expect(plain.outputChunk == nil && plain.fileDiff == nil && plain.progress == nil)
    // A malformed work event is just an unknown kind, never a crash or a wrong view.
    let broken = try JSONDecoder().decode(
        RunEvent.self, from: Data(#"{"kind":"progress","done":"two"}"#.utf8))
    #expect(broken.progress == nil)
}

/// A stream splits into chunks that rejoin to exactly the text, a final partial line included.
@Test func streamChunksRejoinToTheText() {
    let text = "a\nb\nc\nd"
    let two = FakeScript.OutputStream(id: "t", text: text, lines: 2)
    #expect(two.chunks == ["a\nb\n", "c\nd"])
    #expect(FakeScript.OutputStream(id: "t", text: text).chunks.joined() == text)
    #expect(FakeScript.OutputStream(id: "t", text: "", lines: 0).chunks.isEmpty)
}

/// At the default pace a long scripted delay never waits, and output arrives in order.
@Test func streamStepEmitsOutputInOrderWithoutWaiting() async throws {
    let script = try JSONDecoder().decode(
        FakeScript.self,
        from: Data(
            #"""
            {"v":1,"default":{"steps":[
              {"event":{"kind":"tool_call","id":"t1","tool":"shell","input":{}}},
              {"pauseMs":600000},
              {"stream":{"id":"t1","text":"one\ntwo\nthree\n","delayMs":600000}},
              {"event":{"kind":"tool_result","id":"t1","output":{"exitCode":0},"isError":false}}
            ],"result":{}}}
            """#.utf8))
    let clock = ContinuousClock()
    let started = clock.now
    let updates = try await runAsCrewHost(script, "anything", run: "run_1")
    #expect(clock.now - started < .seconds(30))
    let chunks = updates.compactMap(\.event).compactMap(\.event.outputChunk)
    #expect(chunks.map(\.text) == ["one\n", "two\n", "three\n"])
    #expect(chunks.allSatisfy { $0.id == "t1" && $0.stream == "stdout" })
}

/// The triage example shows real work: MSG-201 reads the message, searches, checks the order,
/// and counts progress to the end; the routine runs edit the routine as a diff and stream the
/// routine's output. Every call uses a tool the charter allows or the harness owns.
@Test func triageScriptShowsWorkInProgress() async throws {
    let script = try FakeScript.load(
        from: repositoryRoot.appendingPathComponent("etc/examples/triage/fake-script.json"))
    let allowed: Set = ["inbox.get", "inbox.search", "billing.order", "write", "edit", "shell"]

    let refund = try await runAsCrewHost(
        script, "New message MSG-201: Refund for a duplicate charge", run: "run_1"
    ).compactMap(\.event).map(\.event)
    #expect(refund.compactMap(\.progress).map(\.done) == [1, 2, 3, 4])
    let tools = refund.compactMap { event -> String? in
        if case .toolCall(_, let tool, _) = event.body { return tool }
        return nil
    }
    #expect(tools == ["inbox.get", "inbox.search", "billing.order"])

    for (text, added, removed) in [
        ("New message MSG-134: Duplicate charge on the 3rd", 3, 0),
        ("New message MSG-137: Cheap followers, act now", 2, 2),
    ] {
        let events = try await runAsCrewHost(script, text, run: "run_2").compactMap(\.event)
            .map(\.event)
        let diff = try #require(events.compactMap(\.fileDiff).first, "\(text)")
        #expect(diff.path == "routines/flag-duplicate-charges.sh")
        #expect(diff.counts.added == added && diff.counts.removed == removed, "\(text)")
        #expect(events.compactMap(\.outputChunk).count >= 3, "\(text)")
        for event in events {
            if case .toolCall(_, let tool, _) = event.body { #expect(allowed.contains(tool)) }
        }
    }
}

/// In every example script, output and diffs name an earlier tool call that later answers, so
/// a work pane can hang them under the right call.
@Test(arguments: ["triage/fake-script.json", "refunds/fake-script.json", "digest/fake-script.json"])
func exampleWorkEventsBelongToTheirCalls(_ file: String) throws {
    let script = try FakeScript.load(
        from: repositoryRoot.appendingPathComponent("etc/examples/\(file)"))
    var responses = Array(script.responses.values) + Array(script.joins.values)
    if let fallback = script.defaultResponse { responses.append(fallback) }
    for response in responses {
        var open: Set<String> = []
        var answered: Set<String> = []
        func check(_ id: String?) {
            if let id { #expect(open.contains(id) && !answered.contains(id), "\(file) \(id)") }
        }
        for step in response.allSteps {
            switch step {
            case .event(let event):
                switch event.body {
                case .toolCall(let id, _, _): open.insert(id)
                case .toolResult(let id, _, _): answered.insert(id)
                default:
                    check(event.outputChunk?.id)
                    check(event.fileDiff?.id)
                    if let diff = event.fileDiff {
                        #expect(diff.counts.added + diff.counts.removed > 0)
                    }
                }
            case .stream(let stream): check(stream.id)
            default: break
            }
        }
        #expect(open == answered, "\(file)")
    }
}
