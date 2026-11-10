import Foundation
import Testing

@testable import AryaApp

/// The preview charter (`person:alex` on the inbox) plus Sam, with or without a report.
private func events(report: FeatureJSON? = nil, sent: Bool = false) -> [FeatureEvent] {
    var log = FeatureEventBuilder(start: Date(timeIntervalSince1970: 1_800_000_000))
    var charter = PreviewFixtures.charter
    if case .object(var members) = charter {
        var bindings = members["bindings"]?.array ?? []
        bindings.append(["id": "person:sam", "kind": "person", "channel": "inbox", "name": "Sam"])
        members["bindings"] = .array(bindings)
        if let report { members["report"] = report }
        charter = .object(members)
    }
    log.add("steward.created", actor: .localUser, ["charter": charter, "version": 3])
    if sent {
        log.add("report.sent", ["text": "Weekly report.", "to": [["person": "person:sam"]]])
    }
    return log.events
}

@Suite struct PeopleReportTests {
    @Test func readsTheScheduleAndTheLastSend() {
        let report = PeopleReport(
            events: events(
                report: ["to": ["person:sam", "person:alex"], "cadence": "weekly", "weekday": 3],
                sent: true),
            steward: PreviewFixtures.steward)
        #expect(report.configured)
        #expect(
            report.schedule(names: PeopleDirectory.displayName)
                == "Weekly on Wednesdays at 09:00 UTC to Sam, Alex.")
        #expect(report.lastText == "Weekly report.")
        #expect(report.lastSent != nil)
    }

    @Test func noReportSaysSo() {
        let report = PeopleReport(events: events(), steward: PreviewFixtures.steward)
        #expect(!report.configured)
        #expect(report.schedule(names: { $0 }) == "No report set.")
        #expect(report.stopProposal() == nil)
    }

    @Test func settingUpProposesAReportBlockWithOnlyNonDefaultFields() throws {
        let report = PeopleReport(events: events(), steward: PreviewFixtures.steward)
        var draft = ReportDraft()
        #expect(draft.issues == ["Choose who gets the report."])
        let order = ["person:alex", "person:sam"]
        draft.toggle("person:sam", order: order)
        draft.toggle("person:alex", order: order)
        #expect(draft.to == order)
        let weekly = try #require(report.proposal(draft))
        #expect(weekly.title == "Send a weekly report")
        #expect(
            weekly.charter["report"] == ["to": ["person:alex", "person:sam"], "cadence": "weekly"])
        draft.cadence = "daily"
        draft.weekday = 5
        draft.hour = "17"
        let daily = try #require(report.proposal(draft))
        #expect(
            daily.charter["report"] == [
                "to": ["person:alex", "person:sam"], "cadence": "daily", "hour": 17,
            ])
        draft.hour = "24"
        #expect(report.proposal(draft) == nil)
    }

    @Test func stoppingRemovesTheBlock() throws {
        let report = PeopleReport(
            events: events(report: ["to": ["person:sam"], "cadence": "daily"]),
            steward: PreviewFixtures.steward)
        let stop = try #require(report.stopProposal())
        #expect(stop.charter["report"] == nil)
        #expect(stop.title == "Stop the daily report")
    }
}
