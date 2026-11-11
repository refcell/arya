import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import Arya

/// `count` records a day apart from 2026-09-01, ids `MSG-<n>`.
private func records(_ range: ClosedRange<Int>, choice: String? = nil) -> [HistoryItem] {
    range.map { number in
        let at = Timestamp(millis: 1_788_220_800_000 + Int64(number) * 3_600_000)
        return HistoryItem(
            id: "MSG-\(number)", at: at.description, input: "New message MSG-\(number)",
            choice: choice)
    }
}

private func pages(_ items: [HistoryItem]) -> MemoryHistoryPages {
    MemoryHistoryPages(items: ["inbox": items], now: { "9999-01-01T00:00:00Z" })
}

/// Pages from `items`, failing the page that starts at `failAt` until `heal()` (a flaky
/// connector); records the cursor of every page asked for.
private actor Flaky: HistoryPages {
    let items: [HistoryItem]
    var failAt: String?
    var asked: [String?] = []

    init(_ items: [HistoryItem], failAt: String?) {
        self.items = items
        self.failAt = failAt
    }

    func heal() { failAt = nil }
    func ask(_ cursor: String?) throws {
        asked.append(cursor)
        if let failAt, cursor == failAt { throw WorkspaceError.rejected("connector timed out") }
    }

    nonisolated func open(_ binding: CharterBinding, steward: StewardID) async throws
        -> any HistoryPageReader
    {
        Reader(owner: self)
    }

    struct Reader: HistoryPageReader {
        let owner: Flaky
        func page(cursor: String?, limit: Int) async throws -> HistoryPage {
            try await owner.ask(cursor)
            let page = BindingHistory.page(
                owner.items, HistoryListParams(cursor: cursor, limit: limit))
            return HistoryPage(items: page.items, next: page.next)
        }
        func close() async {}
    }
}

private func inboxWorkspace() async throws -> Opened {
    let opened = try await Opened()
    _ = try await opened.workspace.createSteward(charter: try inboxCharterJSON())
    return opened
}

/// A pass reads at most `maxPages` pages and stores the cursor; the next pass starts there,
/// so a long history is read over passes and each record once. Once at the end, a pass reads
/// only records that arrived since.
@Test func ingestionIsIncrementalAndDedupedBySourceID() async throws {
    let opened = try await inboxWorkspace()
    let workspace = opened.workspace
    await workspace.useHistoryPages(pages(records(1...250)))
    let first = try await workspace.ingestHistory(
        steward: "st_inbox", binding: "inbox", maxPages: 2, pageSize: 100)
    #expect(first.records == 200 && first.lastAdded == 200 && first.passes == 1)
    #expect(first.cursor == "200" && !first.complete && first.lastError == nil)
    #expect(first.line.hasSuffix(", more to read."), "\(first.line)")

    let second = try await workspace.ingestHistory(
        steward: "st_inbox", binding: "inbox", maxPages: 2, pageSize: 100)
    #expect(second.records == 250 && second.lastAdded == 50 && second.complete)
    #expect(second.line.hasSuffix(", up to date."), "\(second.line)")

    // Nothing new: the last page is reread and every id on it is skipped.
    let idle = try await workspace.ingestHistory(steward: "st_inbox", binding: "inbox")
    #expect(idle.records == 250 && idle.lastAdded == 0 && idle.passes == 3)

    // New records, and the source repeating ids it served before: only new ids count.
    await workspace.useHistoryPages(pages(records(1...260) + records(255...258)))
    let more = try await workspace.ingestHistory(steward: "st_inbox", binding: "inbox")
    #expect(more.records == 260 && more.lastAdded == 10 && more.complete)
    #expect(more.oldest == records(1...1)[0].at && more.newest == records(260...260)[0].at)
    #expect(try await workspace.ingestion(steward: "st_inbox") == [more])
}

/// A page that fails stops the pass, keeps what it read, and records the error; the cursor
/// stays at the last good page, so the next pass resumes there instead of starting over.
@Test func aFailedPassResumesFromItsCursor() async throws {
    let opened = try await inboxWorkspace()
    let workspace = opened.workspace
    let flaky = Flaky(records(1...120), failAt: "50")
    await workspace.useHistoryPages(flaky)
    let failed = try await workspace.ingestHistory(
        steward: "st_inbox", binding: "inbox", pageSize: 50)
    #expect(failed.records == 50 && failed.cursor == "50" && !failed.complete)
    #expect(failed.lastError?.contains("connector timed out") == true)
    #expect(failed.line.contains("the last pass stopped"), "\(failed.line)")

    await flaky.heal()
    let resumed = try await workspace.ingestHistory(
        steward: "st_inbox", binding: "inbox", pageSize: 50)
    #expect(resumed.records == 120 && resumed.lastAdded == 70 && resumed.complete)
    #expect(resumed.lastError == nil)
    #expect(await flaky.asked == [nil, "50", "50", "100"])
}

/// A connection that cannot be opened records the error and is not read; another steward's
/// cursor is its own.
@Test func ingestionStatusIsPerStewardAndConnection() async throws {
    let opened = try await inboxWorkspace()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON(id: "st_other"))
    let unread = try await workspace.ingestion(steward: "st_inbox")
    #expect(unread.map(\.line) == ["inbox: history not read yet."])
    #expect(unread[0].passes == 0 && unread[0].cursor == nil)

    await workspace.useHistoryPages(MemoryHistoryPages(items: [:], now: { "" }))
    let broken = try await workspace.ingestHistory(steward: "st_inbox", binding: "inbox")
    #expect(broken.records == 0 && broken.lastError?.contains("serves no history") == true)

    await workspace.useHistoryPages(
        MemoryHistoryPages(
            items: ["st_other/inbox": records(1...3)], now: { "9999-01-01T00:00:00Z" }))
    _ = try await workspace.ingestHistory(steward: "st_other", binding: "inbox")
    let all = try await workspace.ingestion()
    #expect(all.map { "\($0.steward) \($0.records)" } == ["st_inbox 0", "st_other 3"])
    await #expect(throws: WorkspaceError.notFound("binding nowhere")) {
        try await workspace.ingestHistory(steward: "st_inbox", binding: "nowhere")
    }
}

/// Reading a system's history counts it as read in onboarding, shows its records there, and
/// writes one memory note about the source (on the first pass that read records only).
@Test func ingestionFeedsOnboardingAndMemory() async throws {
    let opened = try await inboxWorkspace()
    let workspace = opened.workspace
    let before = try await workspace.onboardingState(steward: "st_inbox")
    #expect(before.steps[0].count == 0)
    #expect(before.ingestion?.map(\.records) == [0])

    let items = records(1...3, choice: "billing") + records(4...4, choice: "bug")
    await workspace.useHistoryPages(pages(items))
    _ = try await workspace.ingestHistory(steward: "st_inbox")
    _ = try await workspace.ingestHistory(steward: "st_inbox")
    let after = try await workspace.onboardingState(steward: "st_inbox")
    #expect(after.systems == ["inbox"])
    #expect(after.steps[0].done && after.steps[0].detail == "Read 1 of 1 system: inbox.")
    #expect(
        after.steps.first { $0.key == "history" }?.detail.hasSuffix(
            "Read 4 past records from 1 system.") == true)
    #expect(after.ingestion?.map(\.records) == [4])

    let notes = try await workspace.memory(steward: "st_inbox").filter {
        $0.tags.contains("history")
    }
    #expect(notes.count == 1)
    #expect(
        notes.first?.text
            == "Read 4 past records from inbox (Sep 1 to Sep 1); people chose billing most "
            + "often (3 of 4).")
}

/// The binding's own process: a real local connector, `arya-binding folder <dir>`, paged
/// through its `history` tool.
@Test func ingestionReadsARealFolderConnector() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-ingest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let csv = """
        id,at,subject,body,choice
        T-1,2026-09-01T09:00:00Z,Export broken,Nothing happens.,bug
        T-2,2026-09-02T10:00:00Z,Refund please,Charged twice.,billing
        T-3,2026-09-03T08:00:00Z,Unsolicited offer,Buy followers.,spam

        """
    try Data(csv.utf8).write(to: folder.appendingPathComponent("history.csv"))
    let binary = Bundle(for: IngestionMarker.self).bundleURL.deletingLastPathComponent()
        .appendingPathComponent("arya-binding").path
    let opened = try await Opened()
    var charter = inboxCharter()
    charter.bindings = [
        .mcp(
            "inbox", command: binary, args: ["folder", folder.path], read: ["get", "history"],
            actions: ["label"])
    ]
    _ = try await opened.workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    let status = try await opened.workspace.ingestHistory(
        steward: "st_inbox", binding: "inbox", pageSize: 2)
    #expect(status.records == 3 && status.complete && status.lastError == nil, "\(status)")
    #expect(status.line == "inbox: 3 records (Sep 1 to Sep 3), up to date.")
}

private final class IngestionMarker {}
