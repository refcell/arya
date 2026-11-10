import Foundation
import Testing

@testable import Arya
@testable import AryaCore

private func reportCharter(_ report: ReportConfig?) throws -> Data {
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.bindings.append(.person("person:sam", channel: "inbox"))
    charter.bindings[charter.bindings.count - 1].name = "Sam"
    charter.report = report
    return try CanonicalJSON.encode(charter)
}

@Test func aReportIsRecordedToItsPeopleAndIsNotDueAgain() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(
        charter: try reportCharter(ReportConfig(to: ["person:sam"], cadence: .weekly)))

    #expect(try await workspace.dueReports() == ["st_inbox"])
    let digest = try await workspace.sendReport(steward: "st_inbox")
    #expect(digest.configured)
    #expect(digest.to == [ReportRecipient(person: "person:sam", name: "Sam", channel: "inbox")])
    #expect(digest.lines.first?.hasPrefix("Weekly report: ") == true)
    #expect(digest.lines.contains { $0.hasPrefix("Did: 0 runs, 0 decisions, 0 actions") })
    #expect(try await workspace.dueReports().isEmpty)
    #expect(try await workspace.sendDueReports().isEmpty)

    let sent = try #require(try await workspace.ledger().last { $0.type == "report.sent" })
    #expect(sent.steward == "st_inbox")
    // The next report covers what happened after this one.
    #expect(try await workspace.reportDigest(steward: "st_inbox").sinceSeq == sent.seq)
}

@Test func withoutAReportBlockTheDigestIsAPreviewAndSendingIsRefused() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try reportCharter(nil))
    let digest = try await workspace.reportDigest(steward: "st_inbox")
    #expect(!digest.configured)
    #expect(digest.to.map(\.person) == ["person:sam"])
    #expect(try await workspace.dueReports().isEmpty)
    await #expect(throws: WorkspaceError.self) {
        try await workspace.sendReport(steward: "st_inbox")
    }
}

@Test func reportValidationNamesUnknownPeopleAndBadTimes() throws {
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.report = ReportConfig(to: ["person:ghost"], weekday: 8, hour: 24)
    #expect(
        charter.validate().map(\.path) == ["report.to[0]", "report.weekday", "report.hour"])
    charter.report = ReportConfig(to: [])
    #expect(charter.validate().map(\.path) == ["report.to"])
}

@Test func theLatestSlotIsTheConfiguredHourOnTheConfiguredWeekday() throws {
    // 2026-11-11 is a Wednesday.
    let wednesday = try #require(ISO8601DateFormatter().date(from: "2026-11-11T08:00:00Z"))
    let daily = ReportSchedule.latestSlot(ReportConfig(to: [], cadence: .daily), before: wednesday)
    #expect(ISO8601DateFormatter().string(from: daily) == "2026-11-10T09:00:00Z")
    let weekly = ReportSchedule.latestSlot(ReportConfig(to: [], weekday: 3), before: wednesday)
    #expect(ISO8601DateFormatter().string(from: weekly) == "2026-11-04T09:00:00Z")
    let monday = ReportSchedule.latestSlot(ReportConfig(to: []), before: wednesday)
    #expect(ISO8601DateFormatter().string(from: monday) == "2026-11-09T09:00:00Z")
}

@Test func theMetricLineSaysValueTargetStatusAndTrend() {
    let start = Date(timeIntervalSince1970: 0)
    let outcome = OutcomeSummary(
        steward: "st", outcome: "o", metric: "accuracy", unit: "", direction: "up",
        target: 0.9, current: 0.92,
        trend: [.init(start: start, value: 0.85), .init(start: start, value: 0.92)],
        windowSeconds: 86_400, status: .onTrack)
    #expect(
        ReportText.metric(outcome, cadence: .weekly)
            == "accuracy 0.92 against a target of 0.90 (on track), up from 0.85 a week ago.")
}
