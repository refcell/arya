import AryaCore
import Foundation
import Testing

@testable import AryaAdapters

/// The repository root, found from this file's path.
let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// The triage example's fake script answers every casebook input with a valid result.
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
    for (index, text) in inputs.enumerated() {
        let adapter = FakeAdapter(script: script, timeouts: Sample.timeouts)
        _ = try await adapter.start(Sample.start(text, run: "run_\(index)"))
        let updates = await collect(adapter, until: \.isResult)
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
