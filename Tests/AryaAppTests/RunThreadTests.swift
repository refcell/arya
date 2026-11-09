import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

private func reply() -> ProposedActionStep {
    ProposedActionStep(
        actionID: "a3", kind: "reply", target: "inbox:MSG-201", summary: "",
        rationale: "acknowledge the customer", policy: "ask", rule: "rule:reply",
        outcome: .awaitingApproval(approval: "ap_1"), binding: "inbox",
        params: ["text": "Thanks for writing in."])
}

@Test func approvalsCarryContentSourceAndWhyItWasHeld() {
    let action = reply()
    #expect(action.content == "Thanks for writing in.")
    #expect(action.paramLines.isEmpty)
    #expect(RunThreadText.approvalTitle(action) == "Reply to inbox:MSG-201")
    #expect(RunThreadText.approvalMeta(action) == "via inbox · risk medium")
    let noted: FeatureJSON = [
        "policy": [
            "rules": [
                [
                    "action": "reply", "binding": "inbox",
                    "note": "Replies to customers need sign-off",
                ]
            ]
        ]
    ]
    #expect(PolicyText.describe(action, charter: noted) == "Replies to customers need sign-off")
    #expect(
        PolicyText.describe(action, charter: nil) == "Reply actions need approval.")
    var unnamed = action
    unnamed.rule = "default"
    #expect(
        PolicyText.describe(unnamed, charter: nil)
            == "Actions the charter does not name need approval.")
    #expect(ActionRisk(kind: "label") == .low)
    #expect(ActionRisk(kind: "close") == .high)
    var route = action
    route.kind = "route"
    route.params = ["queue": "billing"]
    #expect(route.content == nil)
    #expect(route.paramLines == ["queue: billing"])
    #expect(RunThreadText.approvalTitle(route) == "Route on inbox:MSG-201")
}

@Test func threadReadsTheRecordedInputAndKeepsTheSummaryOnce() throws {
    var log = FeatureEventBuilder(start: now)
    log.add(
        "run.started", run: "run_x",
        ["input": ["kind": "manual", "text": "New message MSG-201: Refund for a duplicate charge"]])
    log.add("run.finished", run: "run_x", ["status": "completed", "summary": "Routed MSG-201."])
    let stream = RunStream.build(events: log.events, run: "run_x")
    #expect(stream.input == "New message MSG-201: Refund for a duplicate charge")
    #expect(stream.title == "Routed MSG-201.")
    let utc = try #require(TimeZone(identifier: "UTC"))
    #expect(RunThreadText.meta(stream, timeZone: utc) == "started manually · 08:00:05")
    let visible = RunThreadText.visible(stream.steps)
    #expect(visible.count == 1)
    if case .finished(_, let summary) = visible.first?.kind {
        #expect(summary == "Routed MSG-201.")
    } else {
        Issue.record("expected the finish step")
    }
}

@Test func actionNotesStaySilentWhenTheMarkSaysItAll() {
    var action = reply()
    action.outcome = .executed(output: "{}")
    #expect(RunThreadText.actionNote(action) == nil)
    action.outcome = .rejected(rule: "rule:close")
    #expect(RunThreadText.actionNote(action) == "blocked by rule close")
    #expect(RunThreadText.failed(action))
}

@Test func prettyTextIndentsSortedKeys() {
    let json: FeatureJSON = ["b": [1, 2], "a": "x", "c": [:]]
    #expect(
        json.prettyText == "{\n  \"a\": \"x\",\n  \"b\": [\n    1,\n    2\n  ],\n  \"c\": {}\n}")
    #expect(FeatureJSON.string("plain").prettyText == "plain")
}

private enum DescribedError: Error, CustomStringConvertible {
    case refused
    var description: String { "steward st_triage is paused" }
}

private enum PlainError: Error { case failed }

@Test func unknownErrorsReadAsOneSentence() {
    #expect(FeatureStore.describe(DescribedError.refused) == "Steward st_triage is paused.")
    let plain = FeatureStore.describe(PlainError.failed)
    #expect(!plain.contains("error 0"))
    #expect(plain.contains("PlainError"))
    #expect(plain.hasSuffix("."))
}
