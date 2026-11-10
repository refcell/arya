import AryaAdapters
import AryaCore
import AryaLedger
import AryaRuntime
import Foundation
import Testing

@testable import Arya

/// A temporary home, removed when the test's `TempHome` is deinitialized.
final class TempHome: Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("arya-test-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// The inbox charter as JSON, with `reply` held for approval and `label`/`route` automatic.
func inboxCharterJSON(id: String = "st_inbox") throws -> Data {
    var charter = inboxCharter()
    charter.id = StewardID(unchecked: id)
    charter.bindings = [
        .mcp("inbox", command: "inbox-mcp", read: ["get"], actions: ["label", "route", "reply"])
    ]
    charter.policy = Policy(rules: [
        Policy.Rule(action: "label", decision: .auto),
        Policy.Rule(action: "route", decision: .auto),
    ])
    return try CanonicalJSON.encode(charter)
}

let liveResult: JSONValue = [
    "summary": "Billing question; labeled, routed, reply drafted.",
    "decisions": [["id": "d1", "choice": "billing", "rationale": "Mentions a double charge."]],
    "actions": [
        ["id": "a1", "kind": "label", "binding": "inbox", "target": "inbox:MSG-9"],
        ["id": "a2", "kind": "route", "binding": "inbox", "target": "inbox:MSG-9"],
        [
            "id": "a3", "kind": "reply", "binding": "inbox", "target": "inbox:MSG-9",
            "rationale": "Confirm the refund.",
        ],
    ],
]

struct Opened {
    let home = TempHome()
    let executor = RecordingExecutor()
    let workspace: Workspace

    init(
        _ runs: [FakeScript.Run] = [], leases: any RunLeases = MemoryRunLeases(),
        adapters: (any AdapterFactory)? = nil
    ) async throws {
        workspace = try await Workspace.open(
            home: home.url,
            wiring: Wiring(
                ambient: .fixed(stepMillis: 1),
                adapters: adapters ?? ScriptedFactory(script: FakeScript(runs: runs)),
                executor: executor,
                leases: leases, questionPoll: .milliseconds(1)))
    }

    func types() async throws -> [String] {
        try await workspace.ledger().map(\.type).filter { $0 != "run.adapter.event" }
    }
}

@Test func stewardLifecycleThroughTheFacade() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    let created = try await workspace.createSteward(charter: try inboxCharterJSON())
    #expect(created.id == "st_inbox")
    #expect(created.charterVersion == 1)
    #expect(created.status == .active)
    #expect(!created.ready)
    #expect(try await workspace.stewards().map(\.id) == ["st_inbox"])

    try await workspace.pauseSteward("st_inbox")
    #expect(try await workspace.steward("st_inbox")?.status == .paused)
    try await workspace.resumeSteward("st_inbox")
    #expect(try await workspace.steward("st_inbox")?.status == .active)
    try await workspace.retireSteward("st_inbox")
    #expect(try await workspace.steward("st_inbox")?.status == .retired)
    #expect(try await workspace.steward("st_missing") == nil)

    let types = try await opened.types()
    #expect(
        types == ["steward.created", "steward.paused", "steward.resumed", "steward.retired"])
    #expect(try await workspace.ledger().allSatisfy { $0.actorKind == "human" })
}

@Test func stewardErrorsAreFacadeErrors() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    await #expect(throws: WorkspaceError.self) {
        try await workspace.createSteward(charter: Data("{}".utf8))
    }
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    await #expect(throws: WorkspaceError.rejected("steward st_inbox already exists")) {
        try await workspace.createSteward(charter: try inboxCharterJSON())
    }
    await #expect(throws: WorkspaceError.rejected("st_inbox is active")) {
        try await workspace.resumeSteward("st_inbox")
    }
    await #expect(throws: WorkspaceError.notFound("st_missing")) {
        try await workspace.pauseSteward("st_missing")
    }
}

@Test func charterAndEffortReadTheLiveCharter() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    #expect(try await workspace.effort(for: "st_inbox") == "medium")

    try await workspace.setEffort("high", for: "st_inbox", by: "person:alex")

    #expect(try await workspace.effort(for: "st_inbox") == "high")
    #expect(try await workspace.steward("st_inbox")?.charterVersion == 1)
    let charter = try Charter.load(from: try await workspace.charter("st_inbox"))
    #expect(charter.effort == .high)
    let last = try await workspace.ledger().last
    #expect(last?.type == "steward.effort.set")
    #expect(last?.actorID == "person:alex")
    await #expect(throws: WorkspaceError.self) {
        try await workspace.setEffort("max", for: "st_inbox")
    }
}

@Test func runHoldsAskActionsAndApprovalExecutesThem() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())

    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    #expect(run.status == .finished)
    #expect(run.endStatus == "completed")
    #expect(run.trigger == "manual")
    #expect(run.actionsProposed == 3)
    #expect(try await workspace.runs().map(\.id) == [run.id])
    #expect(try await workspace.runs(steward: "st_other").isEmpty)
    #expect(await opened.executor.requests.map(\.action.kind) == ["label", "route"])

    let pending = try await workspace.approvals()
    #expect(pending.count == 1)
    let approval = try #require(pending.first)
    #expect(approval.kind == .action)
    #expect(approval.actionKind == "reply")
    #expect(approval.target == "inbox:MSG-9")
    #expect(approval.text == "Confirm the refund.")
    #expect(approval.run == run.id)

    let granted = try await workspace.approve(approval.id, note: "looks right")

    #expect(granted.status == .granted)
    #expect(granted.decidedBy == "local")
    #expect(await opened.executor.requests.map(\.action.kind) == ["label", "route", "reply"])
    #expect(try await workspace.approvals().isEmpty)
    #expect(try await workspace.approvals(includeDecided: true).count == 1)
    await #expect(throws: WorkspaceError.self) {
        try await workspace.approve(approval.id)
    }
    #expect(try await opened.types().suffix(2) == ["approval.granted", "action.executed"])
}

@Test func denyRejectsTheHeldAction() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let approval = try #require(try await workspace.approvals().first)

    let denied = try await workspace.deny(approval.id, note: "not yet")

    #expect(denied.status == .denied)
    #expect(try await opened.types().suffix(2) == ["approval.denied", "action.rejected"])
    await #expect(throws: WorkspaceError.notFound("ap_missing")) {
        try await workspace.deny("ap_missing")
    }
}

@Test func failedRunIsReportedNotThrown() async throws {
    let opened = try await Opened([FakeScript.Run(status: .failed, result: ["summary": "no"])])
    _ = try await opened.workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await opened.workspace.startRun(steward: "st_inbox", input: "hello")
    #expect(run.status == .failed)
    #expect(run.failureReason == "adapter_failed")
}

@Test func ledgerReadsVerifiesAndPersistsAcrossOpens() async throws {
    let opened = try await Opened()
    _ = try await opened.workspace.createSteward(charter: try inboxCharterJSON())
    try await opened.workspace.pauseSteward("st_inbox")

    let all = try await opened.workspace.ledger()
    #expect(all.map(\.seq) == [1, 2])
    #expect(try await opened.workspace.ledger(from: 2).map(\.seq) == [2])
    #expect(try await opened.workspace.ledger(limit: 1).map(\.seq) == [1])
    #expect(all[0].steward == "st_inbox")
    #expect(all[0].payload.contains("\"version\":1"))
    #expect(try await opened.workspace.verifyLedger() == LedgerCheck(ok: true, events: 2))

    let again = try await Workspace.open(home: opened.home.url)
    #expect(try await again.steward("st_inbox")?.status == .paused)
}

@Test func verifyReportsTampering() async throws {
    let opened = try await Opened()
    _ = try await opened.workspace.createSteward(charter: try inboxCharterJSON())
    try await opened.workspace.pauseSteward("st_inbox")
    let segment = opened.home.url.appendingPathComponent("ledger/000001.jsonl")
    let text = try String(contentsOf: segment, encoding: .utf8)
    try text.replacingOccurrences(of: "Inbox triage", with: "Inbox triagE")
        .write(to: segment, atomically: true, encoding: .utf8)

    let check = try await opened.workspace.verifyLedger()

    #expect(!check.ok)
    #expect(check.firstBadSeq == 1)
    #expect(check.detail != nil)
}

@Test func eventsReplayThenFollowNewAppends() async throws {
    let opened = try await Opened()
    _ = try await opened.workspace.createSteward(charter: try inboxCharterJSON())
    var iterator = opened.workspace.events(from: 1).makeAsyncIterator()
    #expect(try await iterator.next()?.type == "steward.created")
    try await opened.workspace.pauseSteward("st_inbox")
    #expect(try await iterator.next()?.type == "steward.paused")
}

@Test func openFailsRunsWhoseProcessIsGone() async throws {
    let home = TempHome()
    let ambient = Ambient.fixed(stepMillis: 1)
    let sink = try LedgerEventSink(home: home.url, ambient: ambient)
    try await StewardLifecycle(sink: sink).create(inboxCharter())
    // A run that started and never ended, as if its process was killed mid-stream.
    _ = try await sink.append(
        RuntimeEventDraft(
            type: RunEventType.started, steward: inboxCharter().id,
            run: RunID(unchecked: "run_orphan"), actor: .localUser,
            payload: try CanonicalJSON.jsonValue(
                RunStarted(
                    input: RunInputRecord(kind: .manual, text: "hi"), charterVersion: 1,
                    adapter: "fake", effort: .medium, instructions: "", limits: Limits()))))

    let workspace = try await Workspace.open(home: home.url)

    let run = try #require(try await workspace.runs().first)
    #expect(run.id == "run_orphan")
    #expect(run.status == .failed)
    #expect(run.failureReason == "interrupted")
}

@Test func missingAdapterProfileFailsTheRun() async throws {
    let home = TempHome()
    let workspace = try await Workspace.open(home: home.url)
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await workspace.startRun(steward: "st_inbox", input: "hello")
    #expect(run.status == .failed)
    #expect(run.failureReason == "adapter_exited")
}

@Test func runDetailShowsDecisionsAndDispositions() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let detail = try #require(try await workspace.run(run.id))

    #expect(detail.input == "New message MSG-9")
    #expect(detail.decisions.map(\.choice) == ["billing"])
    #expect(detail.actions.map(\.kind) == ["label", "route", "reply"])
    #expect(detail.actions.map(\.disposition) == [.executed, .executed, .held])
    #expect(detail.actions.map(\.policy) == ["auto", "auto", "ask"])
    let approval = try #require(detail.actions[2].approval)

    _ = try await workspace.deny(approval)

    let after = try #require(try await workspace.run(run.id))
    #expect(after.actions[2].disposition == .rejected)
    #expect(after.actions[2].detail == "approval_denied")
    #expect(try await workspace.run("run_missing") == nil)
}

@Test func replayOfALiveRunMatchesTheRecording() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let report = try await workspace.replay(run: run.id)

    #expect(report.divergences == [])
    #expect(report.events > 2)
    await #expect(throws: WorkspaceError.self) { try await workspace.replay(run: "run_missing") }
}

@Test func changesReportTheNewestSeqIncludingOtherWriters() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let shown = try await workspace.lastSeq()
    #expect(shown > 0)
    let changes = workspace.changes(after: shown)

    // Another workspace on the same home stands in for the CLI writing while the app watches.
    let other = try await Workspace.open(
        home: opened.home.url,
        wiring: Wiring(
            ambient: .fixed(stepMillis: 1), adapters: ScriptedFactory(script: FakeScript()),
            executor: RecordingExecutor(), leases: MemoryRunLeases()))
    try await other.pauseSteward("st_inbox")
    try await other.resumeSteward("st_inbox")
    let newest = try await workspace.lastSeq()
    #expect(newest == shown + 2)

    var seen: [Int] = []
    for try await seq in changes {
        seen.append(seq)
        if seq == newest { break }
    }
    #expect(seen.last == newest)
    #expect(seen.allSatisfy { $0 > shown })
    #expect(seen == seen.sorted())
}

@Test func approvalsCarryContentSourceAndPolicyRule() async throws {
    var result = liveResult
    result[set: "actions"] = [
        [
            "id": "a3", "kind": "reply", "binding": "inbox", "target": "inbox:MSG-9",
            "rationale": "Confirm the refund.",
            "params": ["body": "Hi, the duplicate charge is refunded.\nThanks for waiting."],
        ],
        [
            "id": "a4", "kind": "route", "binding": "inbox", "target": "inbox:MSG-9",
            "params": ["queue": "billing", "priority": 2],
        ],
    ]
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.policy = Policy(rules: [Policy.Rule(action: "route", decision: .ask)])
    let opened = try await Opened([FakeScript.Run(result: result)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    let input = "New message MSG-9: Refund for a duplicate charge\nSecond line."
    let run = try await workspace.startRun(steward: "st_inbox", input: input)
    #expect(run.title == "Billing question; labeled, routed, reply drafted.")

    let pending = try await workspace.approvals()
    #expect(pending.count == 2)
    let reply = try #require(pending.first { $0.actionKind == "reply" })
    #expect(reply.content == "Hi, the duplicate charge is refunded.\nThanks for waiting.")
    #expect(reply.source == input)
    #expect(reply.policyRule == "default")
    #expect(reply.risk == nil)
    let route = try #require(pending.first { $0.actionKind == "route" })
    #expect(route.content == "priority: 2\nqueue: billing")
    #expect(route.policyRule == "rule:route")
    #expect(try await workspace.approval(reply.id) == reply)
    #expect(try await workspace.approve(reply.id).source == input)

    let detail = try #require(try await workspace.run(run.id))
    let decision: DecisionSummary = try #require(detail.decisions.first)
    #expect(decision.choice == "billing")
    #expect(decision.why == "Mentions a double charge.")
}

@Test func runTitlesAndRunNowWithoutInput() async throws {
    #expect(
        RunSummary.title(summary: nil, input: "\n  New message MSG-9  \nmore")
            == "New message MSG-9")
    let long = String(repeating: "word ", count: 30)
    let title = RunSummary.title(summary: long, input: "")
    #expect(title.count <= 60)
    #expect(title.hasSuffix("\u{2026}"))
    #expect(!title.contains("  "))

    let opened = try await Opened([FakeScript.Run(input: "Manual run.", result: ["summary": ""])])
    _ = try await opened.workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await opened.workspace.startRun(steward: "st_inbox")
    #expect(run.title == "Manual run.")
}

@Test func approvalsSayWhichGuardrailHeldThem() async throws {
    var result = liveResult
    result[set: "actions"] = [
        ["id": "a3", "kind": "reply", "binding": "inbox", "target": "inbox:MSG-9"],
        ["id": "a4", "kind": "route", "binding": "inbox", "target": "inbox:MSG-9"],
    ]
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.policy = Policy(rules: [
        Policy.Rule(action: "reply", decision: .ask, note: "Replies to customers need sign-off"),
        Policy.Rule(action: "label", decision: .ask),
    ])
    let opened = try await Opened([FakeScript.Run(result: result)])
    _ = try await opened.workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    let stored = try Charter.load(from: try await opened.workspace.charter("st_inbox"))
    #expect(stored.policy.rules.first?.note == "Replies to customers need sign-off")

    _ = try await opened.workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let pending = try await opened.workspace.approvals()
    let reply = try #require(pending.first { $0.actionKind == "reply" })
    #expect(reply.policyRule == "rule:reply")
    #expect(reply.policyText == "Replies to customers need sign-off")
    let route = try #require(pending.first { $0.actionKind == "route" })
    #expect(route.policyText == "Actions the charter does not name need approval.")
    let label = ProposedAction(id: "a1", kind: "label", binding: "inbox")
    #expect(
        Workspace.policyText("rule:label", action: label, charter: stored)
            == "Label actions need approval (charter rule).")
}

@Test func autonomyHoldsCarryRuntimeRiskAndPlainText() async throws {
    var result = liveResult
    result[set: "actions"] = [
        ["id": "a3", "kind": "reply", "binding": "inbox", "target": "inbox:MSG-9", "risk": "low"]
    ]
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.policy = Policy()
    charter.autonomy = .actLow
    let opened = try await Opened([FakeScript.Run(result: result)])
    _ = try await opened.workspace.createSteward(charter: try CanonicalJSON.encode(charter))

    let run = try await opened.workspace.startRun(steward: "st_inbox", input: "New message MSG-9")

    let approval = try #require(try await opened.workspace.approvals().first)
    #expect(approval.policyRule == "autonomy:act_low:medium")
    #expect(approval.risk == "medium")
    #expect(
        approval.policyText
            == "This steward acts on low-risk actions only; this one is medium risk, "
            + "so it asks you."
    )
    #expect(approval.change == nil)
    let detail = try #require(try await opened.workspace.run(run.id))
    #expect(detail.actions.first?.risk == "medium")
}

@Test func riskReadsTheCharterThenTheKindDefaults() async throws {
    let opened = try await Opened()
    let workspace = opened.workspace
    #expect(try await workspace.risk(kind: "label") == "low")
    #expect(try await workspace.risk(kind: "reply") == "medium")
    #expect(try await workspace.risk(kind: "refund") == "high")
    #expect(try await workspace.risk(kind: "triage") == "medium")
    var charter = inboxCharter()
    charter.id = StewardID(unchecked: "st_inbox")
    charter.bindings = [.mcp("inbox", command: "inbox-mcp", actions: ["reply"])]
    charter.policy.risk = [RiskRule(action: "reply", level: .high)]
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))
    #expect(try await workspace.risk(kind: "reply", steward: "st_inbox") == "high")
    #expect(try await workspace.risk(kind: "label", steward: "st_inbox") == "low")
    await #expect(throws: WorkspaceError.notFound("st_none")) {
        try await workspace.risk(kind: "label", steward: "st_none")
    }
}

@Test func autonomySentencesNeverShowTokens() {
    let reply = ProposedAction(id: "a1", kind: "reply", binding: "inbox")
    func text(_ reason: String) -> String {
        Workspace.policyText(reason, action: reply, charter: nil)
    }
    #expect(
        text("autonomy:suggest:low")
            == "This steward only suggests changes, so a person approves each action.")
    #expect(text("autonomy:observe:low").hasPrefix("This steward only observes"))
    #expect(
        text("autonomy:act_medium:high")
            == "This steward acts on low- and medium-risk actions only; this one is high risk, "
            + "so it asks you.")
    for reason in ["autonomy:suggest:low", "autonomy:bogus", "something_else", "default"] {
        #expect(!text(reason).contains(":") && !text(reason).contains("_"))
    }
}

@Test func labelApprovalsShowWhatChanges() async throws {
    func labeled(_ label: String) -> JSONValue {
        var result = liveResult
        result[set: "actions"] = [
            [
                "id": "a1", "kind": "label", "binding": "inbox", "target": "inbox:MSG-9",
                "params": ["label": .string(label)],
            ]
        ]
        return result
    }
    var charter = try Charter.load(from: try inboxCharterJSON())
    charter.policy = Policy()
    charter.autonomy = .suggest
    let opened = try await Opened([
        FakeScript.Run(input: "New message MSG-9", result: labeled("billing")),
        FakeScript.Run(input: "Again MSG-9", result: labeled("urgent")),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try CanonicalJSON.encode(charter))

    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let first = try #require(try await workspace.approvals().first)
    #expect(first.change?.text == "label: none → billing")
    #expect(first.source == "New message MSG-9")
    #expect(first.policyText?.hasPrefix("This steward only suggests changes") == true)
    _ = try await workspace.approve(first.id)

    _ = try await workspace.startRun(steward: "st_inbox", input: "Again MSG-9")
    let second = try #require(try await workspace.approvals().first)
    #expect(
        second.change
            == .init(
                field: "label", from: "billing", to: "urgent",
                text: "label: billing → urgent"))
}

@Test func denyingAnApprovalLetsTheStewardReplan() async throws {
    let replanned: JSONValue = [
        "summary": "Reply held back; will ask first.",
        "plan": [["id": "p1", "text": "Ask before replying", "status": "pending"]],
    ]
    let opened = try await Opened([
        FakeScript.Run(input: "New message MSG-9", result: liveResult),
        FakeScript.Run(result: replanned),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "New message MSG-9")
    let approval = try #require(try await workspace.approvals().first)
    _ = try await workspace.deny(approval.id, note: "not yet")
    await workspace.settle()
    let types = try await opened.types()
    #expect(types.contains("plan.updated"))
    let runs = try await workspace.runs(steward: "st_inbox")
    #expect(runs.contains { $0.trigger == "replan" })
}
