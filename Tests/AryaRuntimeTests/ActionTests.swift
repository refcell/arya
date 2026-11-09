import AryaCore
import Testing

@testable import AryaRuntime

private let run = RunID(unchecked: "run_000009")

private struct Harness {
    let sink: MemoryEventSink
    let queue: ApprovalQueue
    let executor: RecordingExecutor
    let dispatcher: ActionDispatcher

    init(outcomes: [String: ExecutionOutcome] = [:]) {
        let ambient = Ambient.fixed()
        sink = MemoryEventSink(ambient: ambient)
        queue = ApprovalQueue(sink: sink, ambient: ambient)
        executor = RecordingExecutor(outcomes: outcomes)
        dispatcher = ActionDispatcher(sink: sink, approvals: queue, executor: executor)
    }

    func types() async throws -> [String] { try await sink.events(from: 1).map(\.type) }
}

private func action(_ id: String, _ kind: String, binding: String? = "tracker") -> ProposedAction {
    ProposedAction(id: id, kind: kind, binding: binding, target: "tracker:ISSUE-7")
}

@Test func disposesAutoAskAndDenyInOrder() async throws {
    let harness = Harness()
    let disposals = try await harness.dispatcher.dispose(
        [action("a1", "label"), action("a2", "comment"), action("a3", "close")],
        charter: triageCharter(), run: run)

    #expect(disposals.map(\.verdict.disposition) == [.auto, .ask, .deny])
    #expect(disposals[0].outcome == .succeeded(output: ["ok": true]))
    #expect(disposals[1].approval != nil)
    #expect(
        try await harness.types() == [
            "action.proposed", "action.executed", "action.proposed", "approval.requested",
            "action.proposed", "action.rejected",
        ])
    let requests = await harness.executor.requests
    #expect(requests.map(\.action.id) == ["a1"])
    #expect(requests[0].binding?.id == "tracker")
    #expect(requests[0].approval == nil)
}

@Test func executorFailureIsRecordedWithOutput() async throws {
    let harness = Harness(outcomes: [
        "label": .failed(error: "tracker unavailable", output: ["status": 503])
    ])
    let disposals = try await harness.dispatcher.dispose(
        [action("a1", "label")], charter: triageCharter(), run: run)
    #expect(disposals[0].outcome == .failed(error: "tracker unavailable", output: ["status": 503]))
    let last = try await harness.sink.events(from: 1).last
    #expect(last?.type == "action.failed")
    #expect(last?.payload.objectValue?["error"] == "tracker unavailable")
    #expect(last?.payload.objectValue?["output"] == ["status": 503])
    #expect(last?.draft.actor == .system)
}

@Test func grantedApprovalExecutesAndLinksTheApproval() async throws {
    let harness = Harness()
    let charter = triageCharter()
    let disposal = try await harness.dispatcher.dispose(
        [action("a2", "comment")], charter: charter, run: run)[0]
    let approval = try #require(disposal.approval)
    #expect(await harness.executor.requests.isEmpty)

    let granted = try await harness.queue.grant(approval, by: .person("person:alex"))
    let outcome = try await harness.dispatcher.executeGranted(granted, charter: charter)
    #expect(outcome == .succeeded(output: ["ok": true]))
    let requests = await harness.executor.requests
    #expect(requests.map(\.approval) == [approval])
    #expect(requests[0].run == run)
    let last = try await harness.sink.events(from: 1).last
    #expect(last?.type == "action.executed")
    #expect(last?.payload.objectValue?["approval"] == .string(approval.rawValue))
}

@Test func pendingApprovalCannotExecute() async throws {
    let harness = Harness()
    let charter = triageCharter()
    let disposal = try await harness.dispatcher.dispose(
        [action("a2", "comment")], charter: charter, run: run)[0]
    let approval = try #require(disposal.approval)
    let record = try #require(try await harness.queue.book().records[approval])
    await #expect(throws: ApprovalError.alreadyDecided(record.id, .pending)) {
        try await harness.dispatcher.executeGranted(record, charter: charter)
    }
}

@Test func deniedApprovalIsRejectedNotExecuted() async throws {
    let harness = Harness()
    let disposal = try await harness.dispatcher.dispose(
        [action("a2", "comment")], charter: triageCharter(), run: run)[0]
    let denied = try await harness.queue.deny(try #require(disposal.approval), by: .localUser)
    try await harness.dispatcher.rejectDecided(denied)
    let last = try await harness.sink.events(from: 1).last
    #expect(last?.type == "action.rejected")
    #expect(last?.payload.objectValue?["reason"] == "approval_denied")
    #expect(await harness.executor.requests.isEmpty)
}
