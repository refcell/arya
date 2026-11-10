import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// The repository root, found from this file's path.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// The triage example's fake script answers every casebook input, and every scripted message,
/// with a valid result.
@Test func triageExampleScriptAnswersEveryCase() async throws {
    let examples = repositoryRoot.appendingPathComponent("etc/examples/triage")
    let script = try FakeScript.load(from: examples.appendingPathComponent("fake-script.json"))
    let casebook = String(
        decoding: try Data(contentsOf: examples.appendingPathComponent("casebook.jsonl")),
        as: UTF8.self)
    let inputs = try casebook.split(separator: "\n").map { line in
        try #require(
            try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))["input"]?["text"]?
                .stringValue)
    }
    #expect(!inputs.isEmpty)
    // Every casebook input, plus the scripted messages only the demo and live runs use, except
    // runs scripted to keep running until stopped (checked on their own below, without waits).
    let all =
        inputs
        + script.responses.keys.sorted().filter {
            !inputs.contains($0) && !(script.responses[$0].map(waitsForStop) ?? false)
        }
    #expect(all.count > inputs.count)
    for (index, text) in all.enumerated() {
        let updates = try await runAsCrewHost(script, text, run: "run_\(index)")
        let result = try #require(updates.compactMap(\.result).first)
        #expect(result.status == .completed)
        let decoded = try result.decodedResult()
        #expect(!decoded.decisions.isEmpty)
        // Real outcome data for the app: a plan, reasons, and risk hints (decoding the typed
        // result already rejects unknown step statuses and risk values).
        #expect(!decoded.plan.isEmpty, "\(text)")
        #expect(decoded.decisions.allSatisfy { $0.why?.isEmpty == false }, "\(text)")
        #expect(decoded.actions.allSatisfy { $0.risk != nil && $0.why != nil }, "\(text)")
        let seqs = updates.compactMap(\.event).map(\.seq)
        #expect(seqs == Array(1..<(seqs.count + 1)))
    }
}

/// Whether a response is scripted to keep running until stopped (`sleepMs` or `hang`), as the
/// e2e abort step needs.
func waitsForStop(_ response: FakeScript.Response) -> Bool {
    response.allSteps.contains {
        switch $0 {
        case .sleep, .hang: true
        default: false
        }
    }
}

/// A long-running example run reports that it is working and ends `stopped` as soon as it is
/// stopped, with no wall-clock wait (the e2e abort step relies on this).
@Test func longRunningExampleStopsOnRequest() async throws {
    let examples = repositoryRoot.appendingPathComponent("etc/examples/triage")
    let script = try FakeScript.load(from: examples.appendingPathComponent("fake-script.json"))
    let long = script.responses.filter { waitsForStop($0.value) }.keys.sorted()
    #expect(!long.isEmpty)
    for (index, text) in long.enumerated() {
        let adapter = FakeAdapter(script: script, timeouts: Sample.timeouts)
        let session = try await adapter.start(Sample.start(text, run: "run_long_\(index)"))
            .session
        var stopped = false
        var status: RunStatus?
        for await update in adapter.updates {
            if update.event != nil, !stopped {
                stopped = true
                try await adapter.stop(RunStopParams(session: session, reason: .user))
            }
            if let result = update.result {
                status = result.status
                break
            }
        }
        #expect(stopped && status == .stopped, "\(text)")
    }
}

/// Runs `text` the way a host with in-run crews does: every `host/delegate` runs the child
/// input through the same script and is answered with the child's outcome. A child that does
/// not complete fails the test.
func runAsCrewHost(_ script: FakeScript, _ text: String, run: String) async throws
    -> [AdapterUpdate]
{
    let adapter = FakeAdapter(script: script, timeouts: Sample.timeouts)
    _ = try await adapter.start(Sample.start(text, run: run))
    var updates: [AdapterUpdate] = []
    for await update in adapter.updates {
        updates.append(update)
        if case .delegate(let id, let params) = update {
            let child = FakeAdapter(script: script, timeouts: Sample.timeouts)
            _ = try await child.start(Sample.start(params.input, run: "\(run)_\(params.id)"))
            let outcome = try #require(
                await collect(child, until: \.isResult).compactMap(\.result).first)
            #expect(outcome.status == .completed, "child \(params.id) of \(text)")
            #expect(!(try outcome.decodedResult().actions.isEmpty), "child \(params.id)")
            try await adapter.answerDelegation(
                id,
                HostDelegateResult(
                    run: "\(run)_\(params.id)", status: .completed, result: outcome.result))
        }
        if update.isResult { break }
    }
    return updates
}

/// The damaged-order message hands "draft the refund reply" to a child run, and the parent
/// proposes the reply the child drafted.
@Test func triageExampleDelegatesTheRefundReply() async throws {
    let examples = repositoryRoot.appendingPathComponent("etc/examples/triage")
    let script = try FakeScript.load(from: examples.appendingPathComponent("fake-script.json"))
    let updates = try await runAsCrewHost(
        script, "New message MSG-203: Damaged order, please refund", run: "run_203")
    let asked = updates.compactMap { update -> HostDelegateParams? in
        if case .delegate(_, let params) = update { return params }
        return nil
    }
    #expect(asked.map(\.title) == ["Draft the refund reply"])
    let firstAsked = try #require(asked.first)
    let child = try #require(script.response(for: firstAsked.input))
    let drafted = try #require(child.result).decode(RunResult.self).actions.first
    let parent = try #require(updates.compactMap(\.result).first).decodedResult()
    let proposed = parent.actions.first { $0.kind == "reply" }
    #expect(drafted?.kind == "reply")
    #expect(proposed?.params == drafted?.params)
}

/// An input the script does not know reports itself with status events, never an agent
/// `message`, so the app never shows the fallback as something the agent said.
@Test func triageExampleFallbackIsNeverAMessage() async throws {
    let examples = repositoryRoot.appendingPathComponent("etc/examples/triage")
    let script = try FakeScript.load(from: examples.appendingPathComponent("fake-script.json"))
    let adapter = FakeAdapter(script: script, timeouts: Sample.timeouts)
    _ = try await adapter.start(Sample.start("New message MSG-999: unknown"))
    let updates = await collect(adapter, until: \.isResult)
    let kinds = updates.compactMap(\.event).map(\.event.kind)
    #expect(!kinds.isEmpty)
    #expect(!kinds.contains("message"), "\(kinds)")
    #expect(kinds.contains("status"))
    #expect(updates.compactMap(\.result).first?.status == .completed)
}

@Test func mapAndListFormsDecodeAlike() throws {
    let map = #"""
        {"v":1,"responses":{"a":{"events":[{"kind":"thinking","text":"x"}],"result":{}}},
         "default":{"status":"failed"}}
        """#
    let list = #"""
        {"v":1,"runs":[{"input":"a","steps":[{"event":{"kind":"thinking","text":"x"}}],
          "result":{}},{"status":"failed"}]}
        """#
    let fromMap = try JSONDecoder().decode(FakeScript.self, from: Data(map.utf8))
    let fromList = try JSONDecoder().decode(FakeScript.self, from: Data(list.utf8))
    #expect(fromMap.response(for: "a")?.allSteps == fromList.response(for: "a")?.allSteps)
    #expect(fromMap.response(for: "b")?.status == .failed)
    #expect(fromList.response(for: "b")?.status == .failed)
    let again = try JSONValue(encoding: fromMap).decode(FakeScript.self)
    #expect(again == fromMap)
}

/// Join runs carry run ids in their input, so scripts answer them by delegation id (`joins`).
@Test func joinRunsAreAnsweredByDelegationID() throws {
    let joined = FakeScript.Response(result: ["summary": "joined"])
    let script = FakeScript(
        responses: ["x": FakeScript.Response(result: ["summary": "x"])],
        defaultResponse: FakeScript.Response(result: ["summary": "default"]),
        joins: ["c1": joined])
    let text = #"{"children":[{"delegation":"c1","run":"run_7","status":"completed"}]}"#
    #expect(script.response(for: RunInput(kind: .join, text: text)) == joined)
    let other = #"{"children":[{"delegation":"c9","run":"run_7","status":"completed"}]}"#
    #expect(
        script.response(for: RunInput(kind: .join, text: other))?.result == ["summary": "default"])
    #expect(script.response(for: RunInput(kind: .manual, text: "x"))?.result == ["summary": "x"])
    let decoded = try JSONDecoder().decode(
        FakeScript.self, from: try JSONEncoder().encode(script))
    #expect(decoded.joins == ["c1": joined])
}
