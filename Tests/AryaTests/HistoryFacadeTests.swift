import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import Arya

@Test func historyImportAndReviewQueueThroughTheFacade() async throws {
    let opened = try await Opened(improvementScript())
    let workspace = opened.workspace
    var charter = inboxCharter()
    charter.scorer = .exact(fields: ["decisions.choice", "actions.kind", "actions.target"])
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    #expect(try await workspace.reviewQueue(steward: "st_inbox") == nil)
    _ = try await workspace.importCasebook(
        steward: "st_inbox", data: try casebookLines(), name: "inbox")
    _ = try await workspace.rehearse(steward: "st_inbox")

    let export = """
        {"v":1,"history":[
        {"id":"MSG-1","at":"2026-09-01T08:00:00Z","input":"New message MSG-1","choice":"billing"},
        {"id":"MSG-9","at":"2026-09-02T08:00:00Z","input":"New message MSG-9","choice":"bug",
         "record":{"id":"MSG-9"},"actions":[{"kind":"route","target":"inbox:MSG-9","by":"p:s"}]},
        {"id":"MSG-10","at":"2026-09-03T08:00:00Z","input":"","choice":"bug"}]}
        """
    let summary = try await workspace.importHistory(
        steward: "st_inbox", data: Data(export.utf8), source: "export.jsonl")
    #expect(summary.casebook == "inbox")
    #expect(summary.added == ["hist-MSG-9"])
    #expect(summary.duplicates == ["MSG-1"])
    #expect(summary.invalid == ["MSG-10: empty input"])
    #expect(
        summary.summary == "Added 1 case from export.jsonl; 1 already in the casebook, 1 invalid.")
    #expect(try await workspace.casebooks(steward: "st_inbox").first?.cases == 4)

    // case-3 was answered wrong in the rehearsal: it leads; the new case is not rehearsed yet.
    let queue = try #require(try await workspace.reviewQueue(steward: "st_inbox"))
    #expect(queue.items.map(\.caseID) == ["case-3", "hist-MSG-9", "case-1", "case-2"])
    #expect(queue.items[1].wouldHave == "Not rehearsed yet.")
    #expect(
        queue.items[1].source == "history export.jsonl item MSG-9 by p:s at 2026-09-02T08:00:00Z")
    #expect(queue.progressText == "0 of 4 reviewed · 2 of 4 match what people did")

    let after = try #require(
        try await workspace.reviewCase(steward: "st_inbox", case: "case-1", verdict: "agree"))
    #expect(after.agreed == 1)
    #expect(after.progressText.hasPrefix("1 of 4 reviewed"))
    // The agreement became a learned check, version 1, scored on the live rehearsal.
    let checks = try #require(try await workspace.learnedChecks(steward: "st_inbox"))
    #expect(checks.version == 1 && checks.total == 1)
    #expect(checks.results.first?.check.origin == .agreed)
    #expect(checks.sentence.hasPrefix("Checks v1: "))
    await #expect(throws: WorkspaceError.self) {
        try await workspace.reviewCase(steward: "st_inbox", case: "case-1", verdict: "maybe")
    }
    await #expect(throws: WorkspaceError.notFound("nope")) {
        try await workspace.reviewCase(steward: "st_inbox", case: "nope", verdict: "skip")
    }
    await #expect(throws: WorkspaceError.notFound("binding nowhere")) {
        try await workspace.importHistory(steward: "st_inbox", binding: "nowhere")
    }
}

@Test func onboardingStateFollowsHistoryReviewAndContext() async throws {
    let opened = try await Opened(improvementScript())
    let workspace = opened.workspace
    var charter = inboxCharter()
    charter.scorer = .exact(fields: ["decisions.choice", "actions.kind", "actions.target"])
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))

    let fresh = try await workspace.onboardingState(steward: "st_inbox")
    #expect(
        fresh.steps.map(\.key)
            == ["systems", "people", "processes", "notes", "history", "review", "ready"])
    #expect(fresh.historyCases == 0 && fresh.review == nil && !fresh.ready)
    #expect(fresh.next?.key == fresh.steps.first { !$0.done }?.key)
    #expect(fresh.steps.first { $0.key == "history" }?.detail == "No history imported yet.")
    #expect(fresh.summary.hasPrefix("\(fresh.done) of 7 steps done; next: "))

    _ = try await workspace.importCasebook(
        steward: "st_inbox", data: try casebookLines(), name: "inbox")
    let export = """
        {"v":1,"history":[
        {"id":"MSG-9","at":"2026-09-02T08:00:00Z","input":"New message MSG-9","choice":"bug"}]}
        """
    _ = try await workspace.importHistory(
        steward: "st_inbox", data: Data(export.utf8), source: "export.jsonl")
    _ = try await workspace.reviewCase(steward: "st_inbox", case: "case-1", verdict: "agree")

    let state = try await workspace.onboardingState(steward: "st_inbox")
    let history = try #require(state.steps.first { $0.key == "history" })
    #expect(history.done && history.count == 1 && state.historyCases == 1)
    #expect(history.detail == "Imported 1 case from history.")
    let review = try #require(state.steps.first { $0.key == "review" })
    #expect(!review.done && review.count == 1 && review.total == 4)
    #expect(review.detail.hasPrefix("1 of 4 reviewed"))
    #expect(state.done == fresh.done + 1)
    #expect(state.progress == Double(state.done) / 7)
    // The ready step is eval's go-live gate; no onboard run has happened here.
    let gate = try #require(state.goLive)
    let ready = try #require(state.steps.last)
    #expect(ready.key == "ready" && ready.done == gate.ready && ready.detail == gate.summary)
    #expect(ready.total == gate.conditions.count && state.onboard == nil)
}

/// A refunds binding has no `get`: history records are served as its own read, so a rehearsal
/// of an imported refund answers `billing.order` from the record instead of leaking.
@Test func historyRecordsUseTheBindingsOwnRead() throws {
    func binding(_ read: [String]) throws -> CharterBinding {
        let json = #"{"id":"billing","kind":"mcp","command":"billing-mcp","actions":[],"read":"#
        return try JSONDecoder().decode(
            CharterBinding.self, from: Data((json + "\(read)}").utf8))
    }
    #expect(Workspace.recordTool(try binding(["history", "order"])) == "billing.order")
    #expect(Workspace.recordTool(try binding(["order", "get"])) == "billing.get")
    #expect(Workspace.recordTool(try binding(["history"])) == nil)
}

private final class ProductsMarker {}

/// A steward bound to a real local connector, `arya-binding folder <dir>`: importing from it
/// pages the folder's `history.csv` into the casebook and the review queue, newest first, and
/// each record is served as the binding's `get` so a rehearsal does not leak.
@Test func historyImportsFromARealFolderConnector() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-folder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let csv = """
        id,at,subject,body,action.label.label,target,by,acted_at,choice,outcome
        T-1,2026-09-01T09:00:00Z,Export broken,Nothing happens.,bug,inbox:T-1,person:alex,\
        2026-09-01T09:30:00Z,bug,reopened
        T-2,2026-09-02T10:00:00Z,Refund please,Charged twice.,billing,inbox:T-2,person:sam,\
        2026-09-02T10:20:00Z,billing,resolved
        T-3,2026-09-03T08:00:00Z,Unsolicited offer,Buy followers.,spam,inbox:T-3,person:sam,,spam,

        """
    try Data(csv.utf8).write(to: folder.appendingPathComponent("history.csv"))
    let binary = Bundle(for: ProductsMarker.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("arya-binding").path

    let opened = try await Opened(improvementScript())
    let workspace = opened.workspace
    var charter = inboxCharter()
    charter.bindings = [
        .mcp(
            "inbox", command: binary, args: ["folder", folder.path], read: ["get", "history"],
            actions: ["label", "route"])
    ]
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))

    let summary = try await workspace.importHistory(steward: "st_inbox", binding: "inbox")
    #expect(summary.added == ["hist-T-3", "hist-T-2", "hist-T-1"], "\(summary.summary)")
    #expect(summary.invalid.isEmpty && summary.duplicates.isEmpty)
    let again = try await workspace.importHistory(steward: "st_inbox", binding: "inbox")
    #expect(again.added.isEmpty && again.duplicates.count == 3)
    let queue = try #require(try await workspace.reviewQueue(steward: "st_inbox"))
    #expect(queue.total == 3 && queue.reviewed == 0)
}

/// The http-json connector's `history` page (`{"items": [...], "next": ...}`) imports from a
/// saved file the same way, so a page fetched by hand is a valid export.
@Test func anHTTPJSONHistoryPageImportsAsAnExport() async throws {
    let opened = try await Opened(improvementScript())
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(inboxCharter()))
    let page = """
        {"items": [{"id": "H-1", "at": "2026-09-01T00:00:00Z", "input": "New record H-1",
        "actions": [{"kind": "route", "params": {"queue": "help"}, "by": "person:sam"}],
        "choice": "how-to"}], "next": "1"}
        """
    let summary = try await workspace.importHistory(
        steward: "st_inbox", data: Data(page.utf8), source: "history.json")
    #expect(summary.added == ["hist-H-1"] && summary.invalid.isEmpty)
}

/// The go-live gate reads the steward's own review queue, rehearsal, and checks: right after a
/// history import nothing is agreed yet, so it is not ready and says what is missing.
@Test func goLiveGateReadsTheStewardsEvidence() async throws {
    let opened = try await Opened(improvementScript())
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(inboxCharter()))
    let fresh = try await workspace.goLiveGate(steward: "st_inbox")
    #expect(!fresh.ready && fresh.conditions.map(\.key) == ["review", "rehearsal", "checks"])
    #expect(fresh.summary.hasPrefix("Not ready: import history to review; "))
    await #expect(throws: WorkspaceError.notFound("nope")) {
        try await workspace.goLiveGate(steward: "nope")
    }
}

/// Trajectory grading reads the steward's own events; a steward that has not acted has
/// nothing to grade.
@Test func trajectoriesReadTheStewardsRuns() async throws {
    let opened = try await Opened(improvementScript())
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(inboxCharter()))
    let view = try await workspace.trajectories(steward: "st_inbox")
    #expect(view.runs.isEmpty && view.sentence == "No executed actions to grade yet.")
}
