import Arya
import Foundation
import Testing

@testable import AryaApp

@MainActor final class RecordingPoster: NotificationPosting {
    var notices: [ApprovalNotice] = []
    func post(_ notice: ApprovalNotice) { notices.append(notice) }
}

@MainActor @Suite struct ApprovalNotifierTests {
    func approval(_ id: String, _ status: ApprovalSummary.Status = .pending) -> ApprovalSummary {
        ApprovalSummary(
            id: id, kind: .action, steward: "st_triage", run: "run_1",
            actionKind: "close_issue", target: "tracker:ISSUE-9", text: "A duplicate.",
            status: status, requestedAt: ShellPreviewWorkspace.referenceDate)
    }

    @Test func theFirstLookOnlyPrimes() {
        var notifier = ApprovalNotifier()
        #expect(notifier.newlyPending([approval("ap_1")], stewardNames: [:]).isEmpty)
        let next = notifier.newlyPending(
            [approval("ap_1"), approval("ap_2")], stewardNames: ["st_triage": "Triage keeper"])
        #expect(next.map(\.approval) == ["ap_2"])
        #expect(next.first?.title == "Triage keeper wants to close_issue tracker:ISSUE-9")
        #expect(notifier.newlyPending([approval("ap_2")], stewardNames: [:]).isEmpty)
    }

    @Test func decidedApprovalsAreNeverAnnounced() {
        var notifier = ApprovalNotifier()
        _ = notifier.newlyPending([], stewardNames: [:])
        #expect(notifier.newlyPending([approval("ap_3", .granted)], stewardNames: [:]).isEmpty)
    }

    @Test func questionsReadAsQuestions() {
        let question = ApprovalSummary(
            id: "ap_q", kind: .question, steward: "st_spend", run: "run_2",
            text: "Move the batch?", status: .pending,
            requestedAt: ShellPreviewWorkspace.referenceDate)
        let notice = ApprovalNotifier.notice(for: question, steward: "Spend watcher")
        #expect(notice.title == "Spend watcher has a question")
        #expect(notice.body == "Move the batch?")
    }

    @Test func theModelAnnouncesNewApprovals() async {
        let source = ShellPreviewWorkspace()
        let model = AppModel(source: source)
        let poster = RecordingPoster()
        model.notifications = poster
        await model.refresh()
        #expect(poster.notices.isEmpty)
        await model.deny("ap_1")
        #expect(poster.notices.isEmpty)
        await source.requestApproval(approval("ap_9"))
        await model.refresh()
        #expect(poster.notices.map(\.approval) == ["ap_9"])
    }
}
