import AryaAdapters
import AryaCore
import AryaRuntime
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

@Test func improveViewHasRehearsalReadinessProposalsAndCases() async throws {
    let opened = try await Opened(improvementScript())
    let workspace = opened.workspace
    var charter = inboxCharter()
    charter.scorer = .exact(fields: ["decisions.choice", "actions.kind", "actions.target"])
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    let before = try await workspace.improve(steward: "st_inbox")
    #expect(before.rehearsal == nil)
    #expect(before.rehearsalText == "Not rehearsed yet.")
    #expect(!before.ready)
    #expect(before.cases.isEmpty)

    _ = try await workspace.importCasebook(
        steward: "st_inbox", data: try casebookLines(), name: "inbox")
    let rehearsal = try await workspace.rehearse(steward: "st_inbox")
    var next = charter
    next.outcome = "Every new message is routed within thirty minutes."
    _ = try await workspace.proposeCharter(
        steward: "st_inbox", charter: try CanonicalJSON.encode(next), baseVersion: 1,
        title: "Tighter target")

    let view = try await workspace.improve(steward: "st_inbox")

    #expect(view.rehearsal?.id == rehearsal.id)
    #expect(view.rehearsalText.hasPrefix("Passed 2 of 3 cases on inbox (charter v1), mean score"))
    #expect(!view.ready)
    #expect(view.readinessText.hasPrefix("not ready"))
    #expect(!view.readinessReasons.isEmpty)
    #expect(view.proposals.map(\.gate) == ["Not checked yet."])
    #expect(view.cases.map(\.caseID) == ["case-1", "case-2", "case-3"])
    let failed = try #require(view.cases.last)
    #expect(!failed.passed)
    #expect(failed.wouldHave != failed.expected)
    #expect(!failed.wouldHave.isEmpty && !failed.diff.isEmpty)
    #expect(view.cases.first?.diff == "matches expected")
}

@Test func correctingALiveRunMakesItACase() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let expected = try await workspace.expected(run: run.id, choice: "shipping")
    let value = try CanonicalJSON.decode(JSONValue.self, from: expected)
    #expect(value["decisions"]?.arrayValue?.first?["choice"] == "shipping")
    #expect(value["actions"]?.arrayValue?.isEmpty == false)

    let correction = try await workspace.correct(
        run: run.id, expected: expected, note: "Package questions are shipping.")

    #expect(correction.steward == "st_inbox")
    #expect(!correction.caseID.isEmpty)
    let books = try await workspace.casebooks(steward: "st_inbox")
    #expect(books.first?.version == correction.casebook)
    #expect(books.first?.name == "corrections")
    #expect(books.first?.cases == 1)
    let notes = try await workspace.memory(steward: "st_inbox")
    #expect(notes.map(\.text) == ["Package questions are shipping."])
    #expect(notes.first?.id == correction.note)
    await #expect(throws: WorkspaceError.notFound("run_missing")) {
        try await workspace.correct(run: "run_missing", expected: expected)
    }
    await #expect(throws: WorkspaceError.self) {
        try await workspace.correct(run: run.id, expected: Data("[1]".utf8))
    }
}

/// Answers with `other` for charters whose outcome is `outcome`, else with `live`.
private struct ByOutcome: AdapterFactory {
    var live: FakeScript
    var other: FakeScript
    var outcome: String

    func makeAdapter(for charter: Charter, run: RunID) async throws -> any Adapter {
        try await ScriptedFactory(script: charter.outcome == outcome ? other : live)
            .makeAdapter(for: charter, run: run)
    }
}

@Test func whatIfSaysWhatARunWouldHaveDone() async throws {
    var other = liveResult
    other[set: "decisions"] = [["id": "d1", "choice": "shipping"]]
    let outcome = "Every new message is routed within thirty minutes."
    let opened = try await Opened(
        adapters: ByOutcome(
            live: FakeScript(runs: [FakeScript.Run(result: liveResult)]),
            other: FakeScript(runs: [FakeScript.Run(result: other)]), outcome: outcome))
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let runsBefore = try await workspace.runs(steward: "st_inbox").count
    let executedBefore = await opened.executor.requests.count
    var next = try Charter.load(from: try inboxCharterJSON())
    next.outcome = outcome
    let proposal = try await workspace.proposeCharter(
        steward: "st_inbox", charter: try CanonicalJSON.encode(next), baseVersion: 1)

    let same = try await workspace.whatIf(run: run.id)
    #expect(same.differences.isEmpty)
    let answer = try await workspace.whatIf(run: run.id, proposal: proposal.id)

    #expect(answer.run == run.id)
    #expect(answer.proposal == proposal.id)
    #expect(answer.steward == "st_inbox")
    #expect(answer.rehearsalRun != nil)
    #expect(answer.did.contains("billing"))
    #expect(answer.wouldHave.contains("shipping"))
    #expect(answer.differences.contains("decisions[0].choice"))
    #expect(answer.fixesCorrection == nil)
    #expect(!answer.summary.isEmpty)
    #expect(try await workspace.rehearsals(steward: "st_inbox").isEmpty)
    #expect(try await workspace.runs(steward: "st_inbox").count == runsBefore + 2)
    let executedAfter = await opened.executor.requests.count
    #expect(executedAfter == executedBefore)
    await #expect(throws: WorkspaceError.notFound("run_missing")) {
        try await workspace.whatIf(run: "run_missing")
    }
    await #expect(throws: WorkspaceError.notFound("prop_missing")) {
        try await workspace.whatIf(run: run.id, proposal: "prop_missing")
    }
}
