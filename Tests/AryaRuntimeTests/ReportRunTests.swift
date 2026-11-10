import AryaAdapters
import AryaCore
import Foundation
import Testing

@testable import AryaRuntime

private let triage = StewardID(unchecked: "st_triage")

private func reportCharter(sendRule: PolicyDecision?) -> Charter {
    var charter = triageCharter()
    charter.bindings.append(
        .mcp("mail", command: "mail-server", read: ["receive"], actions: ["send"]))
    var sam = CharterBinding.person("sam", channel: "sam-address")
    sam.via = "mail"
    sam.actions = ["send"]
    charter.bindings.append(sam)
    if let sendRule {
        charter.policy.rules.append(Policy.Rule(action: "send", decision: sendRule))
    }
    return charter
}

@Test func aReportIsItsOwnRunWithOneSendPerPerson() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    try await harness.lifecycle.create(reportCharter(sendRule: .auto))
    let delivery = try #require(
        try await harness.loop.report(
            "Triaged 94% within an hour (target 95%).", subject: "Issue triage weekly report",
            to: ["sam", "nobody"], steward: triage))
    #expect(
        try await harness.types() == [
            "steward.created", "run.started", "action.proposed", "action.executed",
            "run.finished",
        ])
    let started = try #require(try await harness.last("run.started"))
    #expect(started.draft.run == delivery.run)
    #expect(started.payload.objectValue?["input"]?.objectValue?["kind"] == "report")
    let request = try #require(await harness.executor.requests.first)
    #expect(request.action.kind == "send")
    #expect(request.action.binding == "sam")
    #expect(request.relay?.id == "mail")
    #expect(request.action.params?["text"] == "Triaged 94% within an hour (target 95%).")
    #expect(delivery.disposals.map(\.verdict.disposition) == [.auto])
}

@Test func aReportSendWaitsForApprovalWhenPolicyAsks() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    try await harness.lifecycle.create(reportCharter(sendRule: nil))
    let delivery = try #require(
        try await harness.loop.report(
            "digest", subject: "report", to: ["sam"], steward: triage))
    #expect(delivery.disposals.first?.approval != nil)
    #expect(await harness.executor.requests.isEmpty)
    let types = try await harness.types()
    #expect(types.contains("approval.requested"))
    #expect(!types.contains("action.executed"))
    // A denied report send never starts a re-plan.
    let setback = Setback(
        kind: .denied, action: ProposedAction(id: "r1", kind: "send"), detail: "no")
    let replan = try await harness.loop.replan(
        after: delivery.run, steward: triage, setbacks: [setback])
    #expect(replan == nil)
}

@Test func aReportToNoKnownPersonRecordsNothing() async throws {
    let harness = RunHarness(FakeScript.Run(result: triageResult))
    try await harness.lifecycle.create(reportCharter(sendRule: .auto))
    let delivery = try await harness.loop.report(
        "digest", subject: "report", to: ["nobody"], steward: triage)
    #expect(delivery == nil)
    #expect(try await harness.types() == ["steward.created"])
}
