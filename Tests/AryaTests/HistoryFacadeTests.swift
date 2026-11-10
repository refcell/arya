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
        {"id":"MSG-1","input":"New message MSG-1","did":{"decisions":[{"choice":"billing"}]}}
        {"id":"MSG-9","input":"New message MSG-9","did":{"decisions":[{"choice":"bug"}]},"by":"p:s"}
        {"id":"MSG-10","input":"","did":{"decisions":[{"choice":"bug"}]}}
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
    #expect(queue.items[1].source == "history export.jsonl item MSG-9 by p:s")
    #expect(queue.progressText == "0 of 4 reviewed · 2 of 4 match what people did")

    let after = try #require(
        try await workspace.reviewCase(steward: "st_inbox", case: "case-1", verdict: "agree"))
    #expect(after.agreed == 1)
    #expect(after.progressText.hasPrefix("1 of 4 reviewed"))
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
