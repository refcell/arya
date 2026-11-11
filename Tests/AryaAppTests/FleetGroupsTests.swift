import Arya
import Foundation
import Testing

@testable import AryaApp

/// The sidebar's department groups, Portfolio's department roll-up, and New steward templates.
@MainActor @Suite struct FleetGroupsTests {
    func stewards() async -> [StewardSummary] {
        let model = AppModel(source: FakeWorkspaceSource())
        await model.refresh()
        return model.stewards
    }

    @Test func noDepartmentsKeepsOneFlatList() async {
        let all = await stewards()
        let groups = RailGroup.build(sorted: all, departments: [:])
        #expect(groups.count == 1)
        #expect(groups.first?.department == nil)
        #expect(groups.first?.stewards == all)
    }

    @Test func groupsAreAlphabeticalWithUnassignedLastAndKeepNeedOrder() async {
        let all = await stewards()
        let ids = all.map(\.id)
        let groups = RailGroup.build(
            sorted: all, departments: [ids[0]: "Support", ids[1]: "Finance"])
        #expect(groups.map(\.department) == ["Finance", "Support", "Unassigned"])
        #expect(groups.flatMap(\.stewards).count == all.count)
        let shown = RailGroup.visible(groups, collapsed: ["Support"])
        #expect(!shown.contains { $0.id == ids[0] })
        #expect(shown.count == all.count - 1)
    }

    @Test func portfolioCountsAndDepartmentLines() {
        func row(_ id: String, _ department: String, waiting: Int, behind: Bool) -> PortfolioRow {
            PortfolioRow(
                id: id, name: id, outcome: "", metric: "no metric", trend: [], behind: behind,
                state: "live", waiting: waiting, lastRun: "never", nextWake: "on demand",
                health: .onTrack, runsPerDay: [1, 2], failedPerDay: [0, 1],
                department: department)
        }
        let rows = [
            row("a", "Sales", waiting: 0, behind: true),
            row("b", "Support", waiting: 2, behind: false),
            row("c", "Support", waiting: 1, behind: false),
            row("d", "", waiting: 0, behind: false),
        ]
        #expect(PortfolioRow.counts(rows) == "2 need you · 1 behind")
        #expect(PortfolioRow.counts([row("e", "", waiting: 0, behind: false)]) == nil)
        let lines = PortfolioDepartments.lines(rows)
        #expect(lines.map(\.id) == ["Support", "Sales", "Unassigned"])
        #expect(lines[0].waiting == 3)
        #expect(lines[0].runsPerDay == [2, 4])
        #expect(lines[0].failedPerDay == [0, 2])
    }

    @Test func aTemplatePrefillsEveryStep() {
        let source = StewardDraft(
            name: "Lead follow-up", outcome: "Every new lead hears back within a day.",
            metric: "replied_within_1d", unit: "ratio", direction: "up", target: 0.9,
            guardrails: ["Never quote a price", "Never email twice a day"], autonomy: "ask",
            rules: [
                .init(action: "crm.note", decision: "auto"),
                .init(action: "email.send", decision: "ask"),
                .init(action: "crm.delete", decision: "deny"),
            ],
            bindings: [
                .init(
                    id: "crm", kind: "tool", command: "crm-tool",
                    actions: ["crm.note", "email.send"]),
                .init(id: "person:sam", kind: "person", channel: "chat"),
            ],
            effort: "low",
            triggers: [.init(kind: "interval", everySeconds: 3600), .init(kind: "message")],
            adapter: "default", level: "act_low", department: "Sales")
        let draft = NewStewardDraft.template(source)
        #expect(draft.name == "Lead follow-up")
        #expect(draft.target == "0.9")
        #expect(draft.guardrails == "Never quote a price\nNever email twice a day")
        #expect(draft.connections.map(\.id) == ["crm"])
        #expect(draft.people.map(\.name) == ["sam"])
        #expect(draft.signOff == ["email.send"])
        #expect(draft.never == ["crm.delete"])
        #expect(draft.everyMinutes == "60")
        #expect(draft.wakesOnMessage)
        #expect(draft.effort == "low")
        let back = draft.stewardDraft()
        #expect(back.department == "Sales")
        #expect(back.level == "act_low")
        #expect(back.rules.contains { $0.action == "email.send" && $0.decision == "ask" })
    }

    @Test func templateRowsReadAsMetricAndPolicy() {
        let row = TemplateRow.build(
            id: "t", name: "T", department: "Ops", summary: "s",
            draft: StewardDraft(
                name: "T", outcome: "o", metric: "cost_per_lead", unit: "usd", direction: "down",
                target: 40, rules: [.init(action: "x", decision: "auto")], adapter: "default"))
        #expect(row.metric == "cost_per_lead ≤ 40")
        #expect(row.policy == "ask · 1 auto")
    }
}

/// Review 11: every surface reads "running" from workspace live runs, so a stale `running`
/// status left on old runs never lights a steward the rail and status bar show as idle.
@MainActor @Test func everySurfaceAgreesOnWhoIsRunning() async {
    let model = AppModel(source: FakeWorkspaceSource())
    await model.refresh()
    let now = Date()
    // Every steward has an old run still recorded as running.
    for steward in model.stewards {
        let stale = RunSummary(
            id: "stale_\(steward.id)", steward: steward.id, trigger: "schedule",
            charterVersion: 1, status: .running, startedAt: now.addingTimeInterval(-86_400))
        model.runs[steward.id, default: []].insert(stale, at: 0)
    }
    let one = model.stewards[0]
    model.liveLines = [
        LiveLine(
            run: "live", steward: one.id, name: one.name, steps: 2, lastStep: nil,
            progress: nil, started: now.addingTimeInterval(-5))
    ]
    let portfolio = PortfolioRow.build(
        stewards: model.stewards, runs: model.runs, approvals: model.approvals, events: [],
        now: now, live: model.liveLines)
    let fleet = FleetPulse.build(
        stewards: model.stewards, runs: model.runs, approvals: model.approvals, events: [],
        live: model.liveLines, now: now)
    let pulses = model.stewards.map {
        StewardPulse.build(
            steward: $0, runs: model.runs[$0.id] ?? [], approvals: model.approvals, events: [],
            now: now, live: model.liveLines)
    }
    let bar = StatusBarLine.build(
        stewards: model.stewards, runs: model.runs, waiting: 0, events: [], check: nil, now: now,
        liveRuns: model.liveLines)
    let rail = StatusBarLine.running(StatusBarLine.lines(live: model.liveLines))
    #expect(portfolio.filter(\.running).map(\.id) == [one.id])
    #expect(fleet.running == 1)
    #expect(pulses.map(\.running).reduce(0, +) == 1)
    #expect(bar.live.map(\.steward) == [one.id])
    #expect(rail == [one.id])
}

@MainActor @Test func fleetActivitySkipsNoiseAndFlagsFailures() async {
    let model = AppModel(source: FakeWorkspaceSource())
    await model.refresh()
    let steward = model.stewards[0]
    let now = Date()
    func event(_ seq: Int, _ type: String, _ payload: FeatureJSON = [:]) -> FeatureEvent {
        FeatureEvent(
            seq: seq, id: "e\(seq)", at: now.addingTimeInterval(Double(seq - 10) * 60),
            steward: steward.id, run: nil, actor: .localUser, type: type, payload: payload)
    }
    let events = [
        event(1, "run.started"), event(2, "run.adapter.event"), event(3, "run.step.started"),
        event(4, "run.finished", ["status": "failed"]),
    ]
    let lines = FleetActivity.lines(events: events, stewards: model.stewards, now: now)
    #expect(lines.map(\.id) == ["e4", "e1"])
    #expect(lines[0].failed && lines[0].text == "had a run fail")
    #expect(lines[1].text == "started a run")
}

@MainActor @Test func fleetActivityShowsAtMostTwoInARowFromOneSteward() {
    func line(_ id: Int, _ steward: String) -> FleetActivity.Line {
        FleetActivity.Line(
            id: "e\(id)", time: "now", steward: steward, name: steward, text: "", failed: false)
    }
    let lines = [
        line(1, "a"), line(2, "a"), line(3, "a"), line(4, "a"), line(5, "b"), line(6, "a"),
        line(7, "c"),
    ]
    let out = FleetActivity.interleave(lines, limit: 12)
    #expect(out.map(\.id) == ["e1", "e2", "e5", "e3", "e4", "e7", "e6"])
    for index in 2..<out.count {
        #expect(
            !(out[index].steward == out[index - 1].steward
                && out[index].steward == out[index - 2].steward))
    }
}

@MainActor @Test func fleetActivityIsNewestFirstAndMixesOnlyWithinAMinute() {
    let now = Date(timeIntervalSince1970: 1_700_000_040)
    let stewards = ["st_a", "st_b"].map {
        StewardSummary(
            id: $0, name: $0, outcome: "o", charterVersion: 1, status: .active, ready: true)
    }
    var log = FeatureEventBuilder(start: now.addingTimeInterval(-7200))
    log.add("run.started", steward: "st_b", run: "r0")  // two hours ago
    log.add("run.started", steward: "st_a", run: "r1", after: 7100)  // same minute ...
    log.add("run.started", steward: "st_a", run: "r2", after: 1)
    log.add("run.started", steward: "st_a", run: "r3", after: 1)
    log.add("run.started", steward: "st_b", run: "r4", after: 1)  // ... as this one
    let lines = FleetActivity.lines(events: log.events, stewards: stewards, now: now)
    let times = lines.map(\.at)
    // Never older before newer across minutes; the old st_b line stays last.
    #expect(lines.last?.steward == "st_b" && times.last == times.min())
    #expect(lines.prefix(3).map(\.steward).contains("st_b"))
    #expect(lines.count == 5)
}

@Test func actionsReadAsSentencesWithNames() {
    #expect(
        ActionWords.sentence(kind: "send_email", target: "lead:LEAD-1095")
            == "Send an email to LEAD-1095")
    #expect(ActionWords.sentence(kind: "archive", target: "inbox:MSG-1") == "Archive MSG-1")
    #expect(
        ActionWords.humanize("Wants to send_email lead:LEAD-1095.")
            == "Wants to send an email to LEAD-1095.")
    #expect(ActionWords.humanize("Billing owns inbox:MSG-2") == "Billing owns MSG-2")
}

@MainActor @Test func fleetActivityColumnsReadNewestFirstDownThenAcross() {
    let now = Date(timeIntervalSince1970: 1_700_100_000)
    let stewards = ["st_a", "st_b", "st_c"].map {
        StewardSummary(
            id: $0, name: $0, outcome: "o", charterVersion: 1, status: .active, ready: true)
    }
    // A busy steward's burst, an older line from another, and a reload that appended an old
    // event last (the ledger's order is not time order).
    var log = FeatureEventBuilder(start: now.addingTimeInterval(-6000))
    for index in 0..<9 {
        log.add("run.started", steward: "st_a", run: "a\(index)", after: 600)
    }
    log.add("run.started", steward: "st_b", run: "b0", after: 30)
    log.add("run.started", steward: "st_c", run: "c0", at: now.addingTimeInterval(-7200))
    let lines = FleetActivity.lines(events: log.events, stewards: stewards, now: now)
    let columns = FleetActivity.columns(lines)
    let rendered = columns.left + columns.right
    #expect(rendered.count == lines.count)
    for index in 1..<rendered.count {
        #expect(rendered[index - 1].at >= rendered[index].at)
    }
    #expect(rendered.last?.steward == "st_c")
}

@Test func remindersNameTheThingAndAutonomyReadsAsASentence() {
    #expect(
        ActionWords.humanize("Wants to remind inv:INV-1066.")
            == "Wants to remind about invoice INV-1066.")
    #expect(ActionWords.autonomy("act_medium") == "Acts alone on medium risk")
}

@Test func runContextSaysUsageAndPolicyInWords() {
    var facts = RunMetrics()
    facts.tokens = 2100
    facts.costMicros = 4200
    #expect(RunContext.usage(facts) == "2.1k tokens · \(RunMetrics.dollars(4200))")
    #expect(RunContext.usage(RunMetrics()) == nil)
}
