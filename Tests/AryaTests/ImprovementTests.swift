import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import Arya

/// A small casebook like the triage example: three messages; the script answers MSG-3 wrong.
let messages = [("MSG-1", "billing"), ("MSG-2", "bug"), ("MSG-3", "how-to")]

func casebookLines() throws -> Data {
    let lines = try messages.enumerated().map { index, pair in
        try CanonicalJSON.string(inboxCase("case-\(index + 1)", pair.0, pair.1))
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

func improvementScript() -> [FakeScript.Run] {
    messages.map { message, choice in
        var run = inboxRun(message, message == "MSG-3" ? "billing" : choice)
        run.response.result?[set: "measurements"] = [["metric": "routed_within_1h", "value": 1.0]]
        return run
    }
}

extension JSONValue {
    subscript(set key: String) -> JSONValue? {
        get { self[key] }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }
}

@Test func improvementLoopThroughTheFacade() async throws {
    let opened = try await Opened(improvementScript())
    let workspace = opened.workspace
    var charter = inboxCharter()
    charter.scorer = .exact(fields: ["decisions.choice", "actions.kind", "actions.target"])
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))

    let imported = try await workspace.importCasebook(
        steward: "st_inbox", data: try casebookLines(), name: "inbox")
    #expect(imported.cases == 3)
    #expect(try await workspace.casebooks(steward: "st_inbox").map(\.version) == [imported.version])

    let first = try await workspace.rehearse(steward: "st_inbox")
    #expect(first.passed == 2)
    #expect(first.total == 3)
    #expect(first.failed == ["case-3"])
    #expect(first.casebook == "inbox")
    #expect(first.charterVersion == 1)
    let rehearsalRuns = try await workspace.runs(steward: "st_inbox")
    #expect(rehearsalRuns.count == 3)
    #expect(rehearsalRuns.allSatisfy { $0.trigger == "case" })
    #expect(await opened.executor.requests.isEmpty)

    let expected = try await workspace.expected(
        steward: "st_inbox", case: "case-3", choice: "billing")
    let correction = try await workspace.correct(
        steward: "st_inbox", case: "case-3", expected: expected,
        note: "Card updates are billing.")
    #expect(correction.caseID == "case-3")
    #expect(correction.casebook != imported.version)
    #expect(
        try await workspace.casebooks(steward: "st_inbox").first?.correctedFrom
            == imported.version)

    let second = try await workspace.rehearse(steward: "st_inbox")
    #expect(second.passed == 3)
    #expect(second.casebookVersion == correction.casebook)
    #expect(try await workspace.rehearsals(steward: "st_inbox").map(\.id) == [second.id, first.id])

    let ready = try await workspace.markReady(steward: "st_inbox")
    #expect(ready.ready)
    let readyEvent = try #require(try await workspace.ledger().last)
    #expect(readyEvent.type == "steward.ready")
    #expect(readyEvent.payload.contains(second.id))

    let series = try await workspace.metrics(steward: "st_inbox")
    #expect(series.metric == "routed_within_1h")
    #expect(series.windowSeconds == 86_400)
}

@Test func improvementErrors() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    await #expect(throws: WorkspaceError.notFound("casebook for st_inbox")) {
        try await workspace.rehearse(steward: "st_inbox")
    }
    await #expect(throws: WorkspaceError.self) {
        try await workspace.importCasebook(steward: "st_inbox", data: Data("x\n".utf8), name: "b")
    }
    _ = try await workspace.importCasebook(
        steward: "st_inbox", data: try casebookLines(), name: "inbox")
    await #expect(throws: WorkspaceError.notFound("case-9")) {
        try await workspace.correct(steward: "st_inbox", case: "case-9", note: "x")
    }
    await #expect(throws: WorkspaceError.self) {
        try await workspace.correct(steward: "st_inbox", case: "case-1")
    }
}
