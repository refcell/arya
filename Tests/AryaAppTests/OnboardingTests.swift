import Arya
import Foundation
import Testing

@testable import AryaApp

@Test func eachStepNamesWhatBlocksContinue() {
    var draft = NewStewardDraft()
    #expect(draft.problems(.outcome) == ["Give it a name.", "Write the outcome in one sentence."])
    draft.name = "Support inbox triage"
    draft.outcome = "Every message is routed within one hour."
    #expect(draft.problems(.outcome).isEmpty)
    #expect(draft.problems(.metric) == ["Name the metric it moves."])
    draft.metric = "routed_within_1h"
    draft.target = "most"
    #expect(draft.problems(.metric) == ["The target must be a number, like 0.95."])
    draft.target = "0.95"
    draft.automatic = "label, reply"
    draft.signOff = "reply"
    #expect(draft.problems(.guardrails) == ["reply cannot be automatic and need sign-off."])
    draft.automatic = "label"
    draft.systems = "inbox-mcp"
    #expect(draft.problems(.connections).count == 1)
    draft.systems = "inbox: inbox-mcp --stdio"
    draft.everyMinutes = "soon"
    #expect(draft.problems(.schedule).count == 1)
    draft.everyMinutes = ""
    #expect(draft.isComplete)
}

@Test func answersBecomeAStructuredDraft() throws {
    var answers = NewStewardDraft.example
    answers.everyMinutes = "30"
    let draft = answers.stewardDraft()
    #expect(draft.id == "st_support_inbox_triage")
    #expect(draft.target == 0.95)
    #expect(draft.guardrails == ["Never close a conversation.", "Never promise a refund."])
    #expect(draft.autonomy == "ask")
    #expect(draft.rules.map(\.action) == ["label", "route", "reply", "close"])
    #expect(draft.rules.map(\.decision) == ["auto", "auto", "ask", "deny"])
    let inbox = try #require(draft.bindings.first)
    #expect(inbox.kind == "mcp")
    #expect(inbox.command == "inbox-mcp")
    #expect(inbox.actions == ["label", "route", "reply"])
    #expect(draft.bindings.last?.id == "person:alex")
    #expect(draft.bindings.last?.channel == "inbox")
    #expect(draft.triggers.map(\.kind) == ["manual", "interval", "message"])
    #expect(draft.triggers[1].everySeconds == 1800)
    #expect(NewStewardDraft.slug("  Spend -- Watch!") == "spend_watch")
}

@Test func theFacadeCreatesTheStewardFromTheAnswers() async throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("arya-onboarding-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let workspace = try await Workspace.open(home: home)
    try await workspace.record(.createSteward(NewStewardDraft.example.stewardDraft()))
    let stewards = try await workspace.stewards()
    #expect(stewards.map(\.id) == [NewStewardDraft.example.stewardID])
    #expect(stewards.first?.outcome.hasPrefix("Every new message") == true)
}

@Test func thePreviewWorkspaceRecordsACharterTheOverviewReads() async throws {
    let workspace = PreviewWorkspace.triage(now: FeatureTestClock.now)
    try await workspace.record(.createSteward(NewStewardDraft.example.stewardDraft()))
    let events = try await workspace.events()
    let id = NewStewardDraft.example.stewardID
    let state = OutcomeState.build(events: events, steward: id, now: FeatureTestClock.now)
    #expect(state.metric?.name == "routed_within_1h")
    #expect(state.status == .noData)
    #expect(state.readiness == .notReady(reason: "never rehearsed on past work"))
    #expect(state.autonomy.text == "assisted · auto label, route · never close")
}

@Test func firstLaunchSaysWhatAryaIsInOneSentence() {
    #expect(FirstLaunchView.sentence.split(separator: ".").count == 1)
}
