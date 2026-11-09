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
    // Every casebook input, plus the scripted messages only the demo and live runs use.
    let all = inputs + script.responses.keys.sorted().filter { !inputs.contains($0) }
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
