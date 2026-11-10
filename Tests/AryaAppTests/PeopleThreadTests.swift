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
        #expect(PeopleThreadText.counts(thread) == "5 in · 2 out · 2 open hand-offs")
        #expect(PeopleThreadText.tag(thread.entries[0]) == "ask")
        #expect(PeopleThreadText.tag(thread.entries[1]) == "reply")
        #expect(PeopleThreadText.tag(thread.entries[3]) == "hand off")
        #expect(PeopleThreadText.tag(thread.entries[5]) == "report")
        #expect(thread.entries[5].text.hasPrefix("Weekly report"))
        #expect(PeopleThreadText.placeholder("Sam") == "Message as Sam…")
    }

    @Test func theFacadesConversationSuppliesMessagesAndKeepsReportsAndTasks() throws {
        let events = PeopleFixtures.events(steward: "st_triage", person: "person:sam", start: start)
        let folded = thread()
        let first = try #require(folded.entries.first)
        // The facade knows one message and one reply; reports still come from the ledger.
        let reply = try #require(folded.entries.first { !$0.inbound && $0.action == "reply" })
        let conversation = [
            FeatureConversationEntry(
                seq: first.seq, inbound: true, intent: "ask", text: "From the facade", run: nil),
            FeatureConversationEntry(
                seq: reply.seq, inbound: false, intent: nil, text: "Reply", run: reply.run),
        ]
        let merged = PeopleThread(
            events: events, steward: "st_triage", person: "person:sam",
            conversation: conversation)
        #expect(merged.entries.first?.text == "From the facade")
        #expect(merged.entries.first?.id == first.id)
        #expect(merged.entries.filter { $0.action == "reply" }.count == 1)
        #expect(merged.entries.contains { $0.action == "report" })
        #expect(merged.tasks == folded.tasks)
        #expect(merged.working == folded.working)
        #expect(merged.entries.map(\.seq) == merged.entries.map(\.seq).sorted())
    }

    @Test func reportsLineCountsOnlyReports() {
        let folded = thread()
        let line = PeopleThreadText.reports(folded, now: start.addingTimeInterval(86400))
        #expect(line?.hasPrefix("1 sent · last ") == true)
    }
}
