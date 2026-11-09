import AryaAdapters
import AryaCore
import Foundation
import Testing

/// The repository root, found from this file's path.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let triage = repoRoot.appendingPathComponent("etc/examples/triage")

private typealias Object = [String: Any]

private func object(_ name: String) throws -> Object {
    let data = try Data(contentsOf: triage.appendingPathComponent(name))
    return try #require(try JSONSerialization.jsonObject(with: data) as? Object)
}

private func casebook() throws -> [Object] {
    let text = try String(
        contentsOf: triage.appendingPathComponent("casebook.jsonl"), encoding: .utf8)
    return try text.split(separator: "\n").map { line in
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? Object)
    }
}

/// Script responses keyed by input text.
private func scriptRuns() throws -> [String: Object] {
    try #require(try object("fake-script.json")["responses"] as? [String: Object])
}

private func strings(_ value: Any?) -> [String] { value as? [String] ?? [] }
private func objects(_ value: Any?) -> [Object] { value as? [Object] ?? [] }

/// Binding id to the action kinds it may carry out.
private func bindingActions(_ charter: Object) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for binding in objects(charter["bindings"]) {
        if let id = binding["id"] as? String { result[id] = strings(binding["actions"]) }
    }
    return result
}

@Test func triageCharterIsWellFormed() throws {
    let charter = try object("charter.json")
    #expect(charter["v"] as? Int == 1)
    #expect(charter["id"] as? String == "st_triage")
    #expect(!((charter["outcome"] as? String) ?? "").isEmpty)
    let ids = objects(charter["bindings"]).compactMap { $0["id"] as? String }
    #expect(Set(ids).count == ids.count)
    let policy = try #require(charter["policy"] as? Object)
    #expect(policy["default"] as? String == "ask")
    let profiles = try #require(try object("adapters.json")["profiles"] as? Object)
    #expect(profiles[(charter["adapter"] as? String) ?? ""] != nil)
}

@Test func triageCasesAreConsistent() throws {
    let charter = try object("charter.json")
    let reads = objects(charter["bindings"]).flatMap { binding in
        strings(binding["read"]).map { "\(binding["id"] as? String ?? "").\($0)" }
    }
    let cases = try casebook()
    #expect((6...8).contains(cases.count))
    let ids = cases.compactMap { $0["id"] as? String }
    #expect(Set(ids).count == cases.count)
    for item in cases {
        let context = try #require(item["context"] as? Object)
        for result in objects(context["toolResults"]) {
            #expect(reads.contains(result["tool"] as? String ?? ""), "\(item["id"] ?? "")")
        }
        let expected = try #require(item["expected"] as? Object)
        #expect(!objects(expected["decisions"]).isEmpty)
    }
}

@Test func triageScriptCoversEveryCaseAndUsesDeclaredActions() throws {
    let charter = try object("charter.json")
    let actions = bindingActions(charter)
    let responses = try scriptRuns()
    var mismatches: [String] = []
    for item in try casebook() {
        let text = try #require((item["input"] as? Object)?["text"] as? String)
        let response = try #require(responses[text], "no script entry for \(text)")
        let result = try #require(response["result"] as? Object)
        let got = objects(result["decisions"]).compactMap { $0["choice"] as? String }
        let expected = try #require(item["expected"] as? Object)
        let want = objects(expected["decisions"]).compactMap { $0["choice"] as? String }
        if got != want { mismatches.append(item["id"] as? String ?? "") }
    }
    // The end-to-end scenario corrects exactly this case.
    #expect(mismatches == ["case-0006"])
    for (text, response) in responses {
        let result = try #require(response["result"] as? Object)
        for action in objects(result["actions"]) {
            let binding = action["binding"] as? String ?? ""
            let kind = action["kind"] as? String ?? ""
            #expect(actions[binding]?.contains(kind) == true, "\(text): \(kind) via \(binding)")
        }
    }
}

@Test func triageLiveInputHoldsAReply() throws {
    let charter = try object("charter.json")
    let rules = objects((charter["policy"] as? Object)?["rules"])
    let decision = { (kind: String) in
        rules.first { $0["action"] as? String == kind }?["decision"] as? String ?? "ask"
    }
    let responses = try scriptRuns()
    let live = try #require(responses["New message MSG-201: Refund for a duplicate charge"])
    let kinds = objects((live["result"] as? Object)?["actions"]).compactMap {
        $0["kind"] as? String
    }
    #expect(kinds.map(decision) == ["auto", "auto", "ask"])
}

@Test func triageExampleLoadsThroughCore() throws {
    let charter = try Charter.load(
        from: Data(contentsOf: triage.appendingPathComponent("charter.json")))
    #expect(charter.policy.decision(forAction: "reply") == .ask)
    #expect(charter.policy.decision(forAction: "delete") == .deny)
    #expect(charter.policy.decision(forAction: "archive") == .ask)
    let script = try FakeScript.load(from: triage.appendingPathComponent("fake-script.json"))
    #expect(script.response(for: "New message MSG-201: Refund for a duplicate charge") != nil)
    #expect(script.response(for: "anything else") != nil)
    let text = try String(
        contentsOf: triage.appendingPathComponent("casebook.jsonl"), encoding: .utf8)
    for line in text.split(separator: "\n") {
        _ = try Case.load(from: Data(line.utf8))
    }
}
