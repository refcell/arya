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
    draft.customCommand = "tracker-mcp"
    #expect(draft.problems(.connections) == ["Name the custom connection."])
    draft.customID = "tracker"
    draft.people = [.init(id: 0, name: "Alex"), .init(id: 1, name: "alex")]
    #expect(draft.problems(.connections) == ["Each person needs a different name."])
    draft.people.removeLast()
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
    #expect(inbox.actions == ["label", "route", "reply", "close"])
    #expect(draft.bindings.last?.id == "person:alex")
    #expect(draft.bindings.last?.channel == "inbox")
    #expect(draft.triggers.map(\.kind) == ["manual", "interval", "message"])
    #expect(draft.triggers[1].everySeconds == 1800)
    #expect(NewStewardDraft.slug("  Spend -- Watch!") == "spend_watch")
}

@Test func signOffDefaultsFollowAutonomyUntilPicked() {
    var draft = NewStewardDraft()
    draft.connections = [
        .init(id: "inbox", command: "inbox-mcp", actions: ["label", "reply", "refund"], isOn: true)
    ]
    #expect(draft.risk("label") == "low")
    #expect(draft.risk("reply") == "medium")
    #expect(draft.risk("refund") == "high")
    #expect(draft.risk("archive") == "medium")
    #expect(draft.signOffHint == NewStewardDraft.Autonomy.ask.hint)
    #expect(draft.actionKinds.filter(draft.needsSignOff) == ["label", "reply", "refund"])
    draft.autonomy = .auto
    #expect(draft.actionKinds.filter(draft.needsSignOff) == ["refund"])
    #expect(draft.signOffHint == NewStewardDraft.Autonomy.auto.hint)
    draft.setSignOff("reply", true)
    #expect(draft.signOffHint == "Checked actions wait for you; the rest run on their own.")
    #expect(draft.actionKinds.filter(draft.needsSignOff) == ["reply", "refund"])
    draft.setNever("refund", true)
    #expect(draft.stewardDraft().rules.map(\.decision) == ["auto", "ask", "deny"])
}

@Test func theCatalogOffersWhatTheWorkspaceKnows() {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    let bindings: FeatureJSON = [
        ["id": "inbox", "kind": "mcp", "command": "inbox-mcp", "actions": ["label", "reply"]],
        ["id": "person:sam", "kind": "person", "channel": "chat"],
    ]
    let policy: FeatureJSON = ["risk": [["action": "refund", "level": "high"]]]
    log.add(
        "steward.created", steward: "st_a",
        ["charter": ["id": "st_a", "bindings": bindings, "policy": policy]])
    log.add(
        "action.proposed", run: "run_1",
        ["action": ["id": "a1", "kind": "reply"], "disposition": "ask", "risk": "medium"])
    log.add(
        "action.proposed", run: "run_1",
        ["action": ["id": "a2", "kind": "refund"], "disposition": "ask", "risk": "low"])
    let catalog = NewStewardCatalog(events: log.events)
    #expect(catalog.connections.map(\.id) == ["inbox"])
    #expect(catalog.connections.first?.actions == ["label", "reply"])
    #expect(catalog.risks == ["reply": "medium", "refund": "high"])
    #expect(catalog.connections.first { $0.id == "inbox" }?.isOn == false)
    var draft = NewStewardDraft()
    draft.adopt(catalog)
    #expect(draft.connections.count == catalog.connections.count)
    #expect(draft.channels == ["inbox", "email", "chat"])
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

@Test func aNewStewardCarriesItsGuardrailMetrics() throws {
    var answers = NewStewardDraft.example
    #expect(answers.stewardDraft().guardrailMetrics == nil)
    answers.addGuardrailMetric()
    answers.guardrailMetrics[0].name = " reopen_rate "
    answers.guardrailMetrics[0].target = "0.05"
    answers.addGuardrailMetric()
    let draft = answers.stewardDraft()
    let metric = try #require(draft.guardrailMetrics?.first)
    #expect(draft.guardrailMetrics?.count == 1)
    #expect(metric.name == "reopen_rate")
    #expect(metric.direction == "down")
    #expect(metric.target == 0.05)
    let charter = NewStewardPreview.charter(draft)
    #expect(charter["guardrailMetrics"]?.array?.first?["name"]?.string == "reopen_rate")
}
