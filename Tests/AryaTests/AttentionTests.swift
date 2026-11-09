import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private let utc = TimeZone(identifier: "UTC")!

@Test func timeTextIsRelativeToTheGivenClock() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00 UTC
    func relative(_ seconds: Double) -> String {
        TimeText(now.addingTimeInterval(-seconds), now: now, timeZone: utc).relative
    }
    #expect(relative(5) == "just now")
    #expect(relative(5 * 60) == "5 min ago")
    #expect(relative(3 * 3600) == "3 h ago")
    #expect(relative(24 * 3600) == "yesterday")
    #expect(relative(4 * 86_400) == "4 days ago")
    #expect(relative(21 * 86_400) == "3 weeks ago")
    #expect(relative(90 * 86_400) == "2026-10-17")
    #expect(TimeText(now, now: now, timeZone: utc).absolute == "2027-01-15 08:00")
}

@Test func needsYouCollectsApprovalsFailuresAndStaleRehearsals() async throws {
    let opened = try await Opened([
        FakeScript.Run(input: "New message MSG-9", result: liveResult),
        FakeScript.Run(
            input: "Unscripted", status: .failed, result: ["summary": "adapter gave up"]),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.importCasebook(
        steward: "st_inbox", data: try casebookLines(), name: "inbox")
    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    _ = try await workspace.createSteward(charter: try inboxCharterJSON(id: "st_other"))
    _ = try await workspace.startRun(steward: "st_other", input: "Unscripted")

    let items = try await workspace.needsYou(timeZone: utc)

    let kinds = Set(items.map(\.kind))
    #expect(kinds == [.approval, .failedRun, .staleRehearsal])
    let approval = try #require(items.first { $0.kind == .approval })
    #expect(approval.title == "Reply inbox:MSG-9")
    #expect(approval.reason == "Actions the charter does not name need approval.")
    #expect(approval.link.kind == "approval")
    let failed = try #require(items.first { $0.kind == .failedRun })
    #expect(failed.steward == "st_other")
    #expect(failed.title == "Unscripted")
    #expect(failed.reason.hasPrefix("Run failed: "))
    let stale = try #require(items.first { $0.kind == .staleRehearsal })
    #expect(stale.reason == "Never rehearsed on inbox.")
    #expect(stale.link == .init(kind: "rehearsals", id: "st_inbox"))
    #expect(items.map(\.time.date) == items.map(\.time.date).sorted(by: >))
    #expect(items.allSatisfy { !$0.time.relative.isEmpty })
}

@Test func eventDetailShowsPayloadChainAndRunStep() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let decision = try #require(try await workspace.ledger().first { $0.type == "run.decision" })

    let detail = try #require(try await workspace.event(seq: decision.seq, timeZone: utc))

    #expect(detail.entry == decision)
    #expect(detail.payloadText.contains("\n"))
    #expect(detail.payloadText.contains("\"choice\" : \"billing\""))
    #expect(detail.hash.count == 64)
    let previous = try #require(try await workspace.event(seq: decision.seq - 1))
    #expect(detail.prev == previous.hash)
    #expect(detail.step?.run == run.id)
    #expect((detail.step?.index ?? 0) > 1)
    #expect(detail.step?.count == (try await workspace.ledger().filter { $0.run == run.id }.count))
    #expect(try await workspace.event(seq: 1)?.step == nil)
    #expect(try await workspace.event(seq: 10_000) == nil)
}

@Test func backdatedHistoryReadsAsOld() async throws {
    let home = TempHome()
    let weeksAgo = Date().addingTimeInterval(-21 * 86_400)
    let seeding = try await Workspace.open(
        home: home.url,
        ambient: .fixed(start: Timestamp(millis: Int64(weeksAgo.timeIntervalSince1970 * 1000))))
    _ = try await seeding.createSteward(charter: try inboxCharterJSON())

    let live = try await Workspace.open(home: home.url)
    let created = try #require(try await live.ledger().first { $0.type == "steward.created" })
    let detail = try #require(try await live.event(seq: created.seq))
    #expect(detail.time.relative == "3 weeks ago")
}
