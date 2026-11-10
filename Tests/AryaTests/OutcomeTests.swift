import AryaAdapters
import AryaCore
import AryaRuntime
import Foundation
import Testing

@testable import Arya

private func steward(target: Double?) async throws -> Opened {
    let opened = try await Opened(improvementScript())
    var charter = inboxCharter()
    charter.metric.target = target
    _ = try await opened.workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    return opened
}

@Test func outcomeComparesTheNewestWindowWithTheTarget() async throws {
    let opened = try await steward(target: 0.9)
    let workspace = opened.workspace

    let before = try await workspace.outcome(steward: "st_inbox", windows: 3)
    #expect(before.status == .noData)
    #expect(before.current == nil)
    #expect(before.metric == "routed_within_1h")
    #expect(before.outcome == inboxCharter().outcome)
    #expect(before.target == 0.9)

    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-1")
    let after = try await workspace.outcome(steward: "st_inbox", windows: 3)
    #expect(after.current == 1.0)
    #expect(after.status == .onTrack)
    #expect(after.trend.count <= 3)
    #expect(after.trend.last?.value == 1.0)

    var down = inboxCharter().metric
    down.direction = .down
    down.target = 0.5
    #expect(Workspace.status(current: 1.0, metric: down) == .offTrack)
    down.target = nil
    #expect(Workspace.status(current: 1.0, metric: down) == .noTarget)
}

@Test func activityAndRecapReadLikeAStory() async throws {
    let opened = try await steward(target: nil)
    let workspace = opened.workspace
    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-1")

    let activity = try await workspace.activity(steward: "st_inbox")
    #expect(activity.first?.kind == "run")
    #expect(activity.contains { $0.text == "Decided billing" && $0.run == run.id })
    #expect(activity.contains { $0.text == "Label inbox:MSG-1 (executed)" })
    #expect(activity.map(\.seq) == activity.map(\.seq).sorted(by: >))
    #expect(try await workspace.activity(steward: "st_inbox", limit: 2).count == 2)

    let recap = try await workspace.recap(steward: "st_inbox")
    #expect(recap.goal == inboxCharter().outcome)
    #expect(recap.activity.contains { $0.kind == "decision" })
    #expect(recap.activity.allSatisfy { $0.kind == "action" || $0.kind == "decision" })
    #expect(recap.pendingApprovals.map(\.run) == recap.pendingApprovals.map { _ in run.id })
    let later = try await workspace.recap(steward: "st_inbox", since: recap.through)
    #expect(later.activity.isEmpty)
    #expect(later.unresolved.isEmpty)

    #expect(try await workspace.plan(steward: "st_inbox").items.isEmpty)
}

@Test func structuredCreationBuildsTheCharter() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    let draft = StewardDraft(
        name: "Inbox triage", outcome: "Every message is routed within an hour.",
        metric: "routed_within_1h", unit: "ratio", target: 0.95,
        guardrails: ["Never delete a message."], autonomy: "ask",
        rules: [StewardDraft.Rule(action: "label", decision: "auto")],
        bindings: [
            StewardDraft.Binding(
                id: "inbox", kind: "mcp", command: "inbox-mcp", read: ["get"],
                actions: ["label"]),
            StewardDraft.Binding(id: "person:alex", kind: "person", channel: "inbox"),
        ],
        effort: "high",
        triggers: [
            StewardDraft.Trigger(kind: "manual"),
            StewardDraft.Trigger(kind: "message", from: "person:alex"),
        ],
        adapter: "fake")

    let created = try await workspace.createSteward(draft)

    #expect(created.id == "st_inbox_triage")
    let charter = try Charter.load(from: try await workspace.charter(created.id))
    #expect(charter.effort == .high)
    #expect(charter.metric.target == 0.95)
    #expect(charter.policy.rules.first?.decision == .auto)
    #expect(try await workspace.bindings(steward: created.id).map(\.kind) == ["mcp", "person"])
    let people = try await workspace.people(steward: created.id)
    #expect(people.map(\.id) == ["person:alex"])
    #expect(people.first?.takesMessages == true)

    var bad = draft
    bad.direction = "sideways"
    await #expect(throws: WorkspaceError.rejected("direction must be up or down, not sideways")) {
        try await workspace.createSteward(bad)
    }
    #expect(StewardDraft.slug("  Ops: Billing & Refunds! ") == "ops_billing_refunds")
}

@Test func planRiskAndWhyComeFromTheRecordedResult() async throws {
    var result = liveResult
    result[set: "plan"] = [
        ["id": "p1", "text": "Read the message", "status": "done"],
        [
            "id": "p2", "text": "Draft a reply", "status": "in_progress",
            "rationale": "Needs a check",
        ],
    ]
    result[set: "decisions"] = [
        [
            "id": "d1", "choice": "billing", "rationale": "Mentions a double charge.",
            "why": "It is about a charge.",
        ]
    ]
    result[set: "actions"] = [
        [
            "id": "a3", "kind": "reply", "binding": "inbox", "target": "inbox:MSG-9",
            "risk": "medium", "why": "The customer is waiting.",
            "params": ["body": "Refunded."],
        ]
    ]
    let opened = try await Opened([FakeScript.Run(result: result)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    #expect(try await workspace.plan(steward: "st_inbox").items.isEmpty)

    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let plan = try await workspace.plan(steward: "st_inbox")
    #expect(plan.items.map(\.status) == ["done", "in_progress"])
    #expect(plan.items.last?.reason == "Needs a check")
    #expect(plan.run == run.id)
    #expect(plan.reason == "Billing question; labeled, routed, reply drafted.")
    let approval = try #require(try await workspace.approvals().first)
    #expect(approval.risk == "medium")
    #expect(approval.why == "The customer is waiting.")
    let detail = try #require(try await workspace.run(run.id))
    #expect(detail.decisions.first?.why == "It is about a charge.")
    #expect(detail.actions.first?.risk == "medium")
}

@Test func draftsCarryGuardrailMetricsTheWindowAndTheOwner() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    var draft = StewardDraft(
        name: "Inbox triage", outcome: "Every message is routed within an hour.",
        metric: "routed_within_1h", unit: "ratio", target: 0.95, adapter: "fake",
        owner: "person:alex",
        guardrailMetrics: [
            StewardDraft.GuardrailMetric(
                name: "reopened", unit: "ratio", direction: "down", target: 0.05)
        ],
        windowDays: 14)
    let created = try await workspace.createSteward(draft)
    let charter = try Charter.load(from: try await workspace.charter(created.id))
    #expect(charter.owner == "person:alex")
    #expect(charter.metric.windowDays == 14)
    #expect(charter.guardrailMetrics?.map(\.name) == ["reopened"])
    #expect(charter.guardrailMetrics?.first?.direction == .down)

    draft.name = "Other"
    draft.guardrailMetrics = [StewardDraft.GuardrailMetric(name: "x", unit: "n", direction: "left")]
    await #expect(
        throws: WorkspaceError.rejected("guardrail metric direction must be up or down, not left")
    ) {
        try await workspace.createSteward(draft)
    }
}
