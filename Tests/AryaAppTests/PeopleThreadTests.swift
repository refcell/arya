import Foundation
import Testing

@testable import AryaApp

@Suite struct PeopleThreadTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func thread(_ person: String = "person:sam") -> PeopleThread {
        let events =
            PeopleFixtures.events(steward: "st_triage", person: "person:sam", start: start)
            + PeopleFixtures.events(steward: "st_other", person: "person:sam", start: start)
        return PeopleThread(events: events, steward: "st_triage", person: person)
    }

    @Test func readsInboundMessagesAndOutboundRepliesInOrder() {
        let thread = thread()
        #expect(
            thread.entries.map(\.inbound) == [true, false, true, true, false, false, true, true])
        let reply = thread.entries[1]
        #expect(reply.action == "reply")
        #expect(reply.run == "run_pt1")
        #expect(reply.text.hasPrefix("It asks where a package is"))
        #expect(thread.entries[2].intent == "correct")
    }

    @Test func handoffsAreTasksWithTheirRunsStatusNewestFirst() {
        let tasks = thread().tasks
        #expect(tasks.map(\.status) == [.running, .waiting, .done])
        #expect(tasks.map(\.run) == ["run_pt4", "run_pt3", "run_pt2"])
        #expect(thread().open == 2)
    }

    @Test func aDecidedApprovalMeansRunningAndAFailureIsFailed() {
        var events = PeopleFixtures.events(
            steward: "st_triage", person: "person:sam", start: start)
        var log = FeatureEventBuilder(start: start.addingTimeInterval(86_400))
        log.add("approval.granted", run: "run_pt3", ["approval": "ap_pt3"])
        log.add("run.failed", run: "run_pt2", [:])
        events += log.events.map {
            var event = $0
            event.id = "late_\(event.seq)"
            return event
        }
        let tasks = PeopleThread(events: events, steward: "st_triage", person: "person:sam").tasks
        #expect(tasks.map(\.status) == [.running, .running, .failed])
    }

    @Test func anActiveRunForTheirMessageShowsWhatTheStewardIsDoing() throws {
        let working = try #require(thread().working)
        #expect(working.run == "run_pt4")
        #expect(working.doing == "calling inbox.search")
        #expect(working.steps == 2)
        let live = PeopleThread(
            events: PeopleFixtures.live(steward: "st_triage", person: "person:sam", start: start),
            steward: "st_triage", person: "person:sam")
        #expect(live.working?.run == "run_live")
        #expect(live.tasks.map(\.status) == [.running])
        #expect(thread("person:alex").working == nil)
    }

    @Test func aMessageWithoutARunIsQueuedAndNotWorking() {
        var log = FeatureEventBuilder(start: start)
        log.add(
            "inbox.message",
            ["from": "person:sam", "intent": "handoff", "text": "Sort the backlog"])
        let thread = PeopleThread(
            events: log.events, steward: PreviewFixtures.steward, person: "person:sam")
        #expect(thread.tasks.map(\.status) == [.queued])
        #expect(thread.working == nil)
    }

    @Test func otherPeopleSeeOnlyTheirOwnThread() {
        let thread = thread("person:alex")
        #expect(thread.entries.isEmpty)
        #expect(thread.tasks.isEmpty)
    }

    @Test func countsAndTags() {
        let thread = thread()
        #expect(PeopleThreadText.counts(thread) == "5 in · 3 out · 2 open hand-offs")
        #expect(PeopleThreadText.tag(thread.entries[0]) == "ask")
        #expect(PeopleThreadText.tag(thread.entries[1]) == "reply")
        #expect(PeopleThreadText.tag(thread.entries[3]) == "hand off")
        #expect(PeopleThreadText.tag(thread.entries[5]) == "report")
        #expect(thread.entries[5].text.hasPrefix("Weekly report"))
        #expect(PeopleThreadText.placeholder("Sam") == "Message as Sam…")
    }
}
