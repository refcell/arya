import Foundation
import Testing

@testable import AryaApp

@Test func liveRunShowsProgressAgainstTheStewardsUsualRun() throws {
    let now = FeatureTestClock.now
    let events = PreviewFixtures.live(now: now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.inProgressRun)
    #expect(stream.status == .running)
    let progress = try #require(stream.progress)
    #expect(progress.expected == 5)
    #expect(progress.done == RunThreadText.steps(stream.steps).count)
    #expect(progress.text(now: now) == "2 of ~5 steps · 4 s")
    #expect(progress.fraction > 0 && progress.fraction < 1)
}

@Test func theOpenToolCallIsTheRunningBlock() {
    let now = FeatureTestClock.now
    let events = PreviewFixtures.live(now: now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.inProgressRun)
    let work = RunWork.build(stream: stream, events: events)
    #expect(work.blocks.last?.title == "billing.order")
    #expect(work.blocks.last?.mark == .running)
    #expect(work.blocks.first?.mark == .ok)
}

@Test func finishedRunsHaveNoProgressAndNoHistoryReadsPlainly() {
    let now = FeatureTestClock.now
    let finished = RunStream.build(
        events: PreviewFixtures.triage(now: now), run: PreviewFixtures.finishedRun)
    #expect(finished.progress == nil)
    let lone = RunProgress(done: 3, expected: nil, started: now.addingTimeInterval(-2))
    #expect(lone.text(now: now) == "3 steps · 2 s")
}

@Test func runKeysMoveBetweenWorkSteps() {
    let now = FeatureTestClock.now
    let stream = RunStream.build(
        events: PreviewFixtures.live(now: now), run: PreviewFixtures.inProgressRun)
    let ids = stream.steps.filter { RunWork.isWork($0.kind) }.map(\.id)
    #expect(RunKeys.step(stream, from: nil, by: 1) == ids.first)
    #expect(RunKeys.step(stream, from: ids.first, by: 1) == ids.last)
    #expect(RunKeys.step(stream, from: ids.last, by: 1) == ids.last)
    #expect(RunKeys.action(for: "c") == .compose)
    #expect(RunKeys.action(for: "x") == nil)
}

@Test func runtimeStepEventsStreamIntoOneToolCall() throws {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    log.add("run.started", run: "r", ["trigger": "manual"])
    log.add(
        "run.step.started", run: "r", ["step": "s1", "tool": "shell", "input": #"{"cmd":"ls"}"#])
    log.add("run.step.output", run: "r", ["step": "s1", "seq": 1, "text": "a.txt\n", "bytes": 6])
    log.add("run.step.output", run: "r", ["step": "s1", "seq": 2, "text": "b.txt\n", "bytes": 6])
    let open = RunStream.build(events: log.events, run: "r")
    guard case .toolCall(let running) = open.steps.last?.kind else {
        Issue.record("no tool call")
        return
    }
    #expect(running.output == .string("a.txt\nb.txt\n"))
    #expect(running.input["cmd"] == .string("ls"))
    log.add(
        "run.step.finished", run: "r",
        ["step": "s1", "ok": true, "bytes": 12, "chunks": 2, "millis": 1500])
    guard case .toolCall(let done) = RunStream.build(events: log.events, run: "r").steps.last?.kind
    else {
        Issue.record("no tool call")
        return
    }
    #expect(done.durationSeconds == 1.5)
    #expect(!done.isError)
}

@Test func adapterDiffsAndProgressFeedTheWorkPane() throws {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    log.add("run.started", run: "r", ["trigger": "manual"])
    log.add(
        "run.adapter.event", run: "r",
        PreviewFixtures.wire(
            1, ["kind": "diff", "path": "src/a.txt", "patch": "@@ -1 +1 @@\n-old\n+new"]))
    log.add(
        "run.adapter.event", run: "r",
        PreviewFixtures.wire(2, ["kind": "progress", "done": 2, "total": 7]))
    let stream = RunStream.build(events: log.events, run: "r")
    #expect(stream.progress?.text(now: FeatureTestClock.now).hasPrefix("2 of ~7 steps") == true)
    let diff = try #require(RunWork.build(stream: stream, events: log.events).diffs.first)
    #expect(diff.title == "src/a.txt")
    #expect(diff.countText == "+1 −1")
}

@Test func messageInputsReadInPeoplesWords() {
    #expect(
        RunInput.message("person:priya hands this to you: Close ISSUE-9")
            == "Priya handed this to you: Close ISSUE-9")
    #expect(RunInput.message("person:sam-lee asks: Why?") == "Sam Lee asked: Why?")
    #expect(RunInput.message("New message MSG-1") == "New message MSG-1")
}

@Test func dryRunsDoNotClaimEffects() {
    var drafted = ProposedActionStep(
        actionID: "a1", kind: "label", target: "inbox:MSG-1", summary: "", rationale: "",
        policy: "auto", outcome: .executed(output: ""))
    drafted.dryRun = true
    let step = StreamStep(id: "e", number: 1, at: FeatureTestClock.now, kind: .action(drafted))
    #expect(RunStream.isDryRun([step]))
    drafted.dryRun = false
    let real = StreamStep(id: "e", number: 1, at: FeatureTestClock.now, kind: .action(drafted))
    #expect(!RunStream.isDryRun([real]))
}

@Test func undoShowsOnlyWhenTheRunAppliedSomething() {
    func facts(applied: Int, drafted: Int, dryRun: Bool) -> FeatureRunFacts {
        FeatureRunFacts(
            running: false, started: FeatureTestClock.now, elapsedSeconds: 3, decisions: 1,
            toolCalls: 0, actionsProposed: applied + drafted, actionsApplied: applied,
            actionsDrafted: drafted, actionsWaiting: 0, stepIndex: 3, estimatedSteps: nil,
            dryRun: dryRun)
    }
    #expect(
        UndoState.of(facts: facts(applied: 0, drafted: 2, dryRun: true), steps: [])
            == .nothingApplied)
    #expect(UndoState.of(facts: facts(applied: 0, drafted: 0, dryRun: false), steps: []) == .hidden)
    #expect(UndoState.of(facts: facts(applied: 1, drafted: 1, dryRun: false), steps: []) == .shown)
    var drafted = ProposedActionStep(
        actionID: "a1", kind: "label", target: "inbox:MSG-1", summary: "", rationale: "",
        policy: "auto", outcome: .executed(output: ""))
    drafted.dryRun = true
    let step = StreamStep(id: "e", number: 1, at: FeatureTestClock.now, kind: .action(drafted))
    #expect(UndoState.of(facts: nil, steps: [step]) == .nothingApplied)
}

@Test func dryRunTitlesUseEachActionsVerbPhrase() {
    func step(_ kind: String, _ target: String, _ params: FeatureJSON) -> StreamStep {
        var action = ProposedActionStep(
            actionID: kind, kind: kind, target: target, summary: "", rationale: "",
            policy: "auto", outcome: .executed(output: ""), params: params)
        action.dryRun = true
        return StreamStep(id: kind, number: 1, at: FeatureTestClock.now, kind: .action(action))
    }
    let cases: [(StreamStep, String)] = [
        (step("label", "inbox:MSG-1", ["label": "spam"]), "labeled MSG-1 as spam"),
        (
            step("assign", "tracker:ISSUE-7", ["to": "person:alex"]),
            "assigned ISSUE-7 to Alex"
        ),
        (
            step("mark", "crm:LEAD-1095", ["mark": "disqualified"]),
            "marked LEAD-1095 as disqualified"
        ),
        (step("send_email", "lead:LEAD-1095", .null), "sent email LEAD-1095"),
        (
            step("refund", "billing:ORDER-1", ["amount": 12, "currency": "USD"]),
            "refunded 12.00 USD on ORDER-1"
        ),
    ]
    for (step, phrase) in cases {
        guard case .action(let action) = step.kind else { continue }
        #expect(RunTitle.phrase(action) == phrase)
    }
    let title = RunTitle.dryRun(
        summary: "LEAD-1095 (demo request, wants pricing): disqualified.",
        steps: [cases[2].0, cases[3].0])
    #expect(
        title
            == "Dry run: would have marked LEAD-1095 as disqualified"
            + " and sent email LEAD-1095."
    )
    #expect(RunTitle.text(summary: "Closed it.", dryRun: false) == "Closed it.")
    #expect(
        RunTitle.text(summary: "Closed it.", dryRun: true) == "Dry run, nothing applied: Closed it."
    )
    #expect(RunTitle.verb("send_email") == "send email")
}

@Test func oneElapsedFormatForEverySurface() {
    let facts = FeatureRunFacts(
        running: true, started: FeatureTestClock.now, elapsedSeconds: 2, decisions: 0,
        toolCalls: 0, actionsProposed: 0, actionsApplied: 0, actionsDrafted: 0,
        actionsWaiting: 0, stepIndex: 1, estimatedSteps: nil, dryRun: false)
    #expect(facts.elapsedText(now: FeatureTestClock.now.addingTimeInterval(8.7)) == "8 s")
    #expect(facts.elapsedText(now: FeatureTestClock.now.addingTimeInterval(124)) == "2m 4s")
    var done = facts
    done.running = false
    #expect(done.elapsedText(now: FeatureTestClock.now.addingTimeInterval(500)) == "2.0 s")
    #expect(RunTitle.participle("reply") == "replied")
    #expect(RunTitle.participle("close") == "closed")
}

@Test func repliesStreamInAndToolsFoldWhenDone() throws {
    let events = PreviewFixtures.streaming(now: FeatureTestClock.now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.streamingRun)
    let calls = stream.steps.compactMap { step -> ToolCallStep? in
        if case .toolCall(let call) = step.kind { return call }
        return nil
    }
    #expect(calls.map(\.finished) == [true, false])
    #expect(calls[1].output?.string?.hasSuffix("none\n") == true)
    guard case .message(let role, let text) = stream.steps.last?.kind else {
        Issue.record("no streaming reply")
        return
    }
    #expect(role == "streaming")
    #expect(text.hasPrefix("Sorry the lamp arrived broken. I checked ORDER-2210"))
    let output = RunWork.build(stream: stream, events: events).output
    #expect(output.map(\.tag) == ["▸ shell", "▸ shell", "▸ compose"])
    #expect(output[1].text.contains("captured $48.00"))
    #expect(RunThreadText.toolMeta(calls[1], elapsed: 3.4) == "running… 3 s")
}

@Test func runKeysCoverTabsFollowAndSteps() {
    #expect(RunKeys.action(for: "3") == .tab(.log))
    #expect(RunKeys.action(for: "f") == .follow)
    #expect(RunKeys.action(for: "j") == .next)
    #expect(RunKeys.action(for: "9") == nil)
}

@Test func runBriefTicksTheStepsOfALiveRun() {
    let events = PreviewFixtures.streaming(now: FeatureTestClock.now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.streamingRun)
    let brief = RunBrief.build(stream: stream, events: events, expected: 6)
    #expect(brief.trigger == "Started by a message")
    #expect(brief.plan.map(\.mark) == [.done, .current, .current, .next])
    #expect(brief.plan.last?.text == "~3 more steps expected")
    #expect(brief.planSource == "steps so far")
}

@Test func runBriefUsesTheRunsOwnPlanAndNamesWhoHandedItOff() {
    var log = FeatureEventBuilder(start: FeatureTestClock.now)
    log.add(
        "run.started", run: "r",
        ["trigger": "message", "input": "person:priya hands this to you: Close ISSUE-9"])
    log.add(
        "plan.updated", run: "r",
        [
            "items": [
                ["id": "1", "text": "Read ISSUE-9", "status": "done"],
                ["id": "2", "text": "Close it", "status": "in_progress"],
                ["id": "3", "text": "Tell Priya", "status": "pending"],
            ]
        ])
    let stream = RunStream.build(events: log.events, run: "r")
    let brief = RunBrief.build(stream: stream, events: log.events, expected: nil)
    #expect(brief.trigger == "Priya handed this off")
    #expect(brief.plan.map(\.mark) == [.done, .current, .next])
    #expect(brief.planSource == "the run's plan")
}

@Test func refsReadAsNamesAndDryRunsSplitIntoTitleAndPill() {
    #expect(EntityName.split("person:alex").name == "Alex")
    #expect(EntityName.split("person:alex").system == nil)
    #expect(EntityName.split("tracker:ISSUE-7").name == "ISSUE-7")
    #expect(EntityName.split("tracker:ISSUE-7").system == "tracker")
    #expect(EntityName.split("refund").system == nil)
    #expect(
        EntityName.humanize("Assign tracker:ISSUE-7 to person:sam-lee at 09:01, see https://x.io")
            == "Assign ISSUE-7 to Sam Lee at 09:01, see https://x.io")
    let parts = RunTitle.parts(
        summary: "Dry run: would have labeled inbox:MSG-9 as spam.", dryRun: false)
    #expect(parts == RunTitle.Parts(title: "Labeled MSG-9 as spam.", isDryRun: true))
}

@Test func briefCountsFromTheRunFactsAndAdaptersReadAsNames() {
    let events = PreviewFixtures.streaming(now: FeatureTestClock.now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.streamingRun)
    let brief = RunBrief.build(stream: stream, events: events, done: 9, expected: 9)
    #expect(!brief.plan.contains { $0.text.contains("more step") })
    let behind = RunBrief.build(stream: stream, events: events, done: 4, expected: 6)
    #expect(behind.plan.last?.text == "~2 more steps expected")
    #expect(AdapterName.display("demo-lead_follow_up") == "Lead follow up")
    #expect(AdapterName.display("fake-triage") == "Triage (test)")
    #expect(AdapterName.display("fake-triage", named: "Triage bot") == "Triage bot")
}

@Test func aStepIsOneTimedThreadRowAndTheBriefListsEachOne() {
    for events in [
        PreviewFixtures.streaming(now: FeatureTestClock.now),
        PreviewFixtures.live(now: FeatureTestClock.now),
    ] {
        let run = events.first { $0.type == "run.started" }?.run ?? ""
        let stream = RunStream.build(events: events, run: run)
        let steps = RunThreadText.steps(stream.steps)
        let rows = RunThreadText.visible(stream.steps).filter { RunThreadText.isStep($0.kind) }
        #expect(rows.map(\.id) == steps.map(\.id))
        #expect(!steps.contains { if case .decision = $0.kind { true } else { false } })
        let brief = RunBrief.build(stream: stream, events: events, expected: nil)
        #expect(brief.plan.filter { $0.mark != .next }.count == steps.count)
    }
}

@Test func oneHumanizerForEveryLane() {
    #expect(HumanText.name("person:priya-shah") == "Priya Shah")
    #expect(HumanText.pastVerb("send_email") == "sent email")
    #expect(
        HumanText.action(kind: "assign", target: "tracker:ISSUE-7", params: ["to": "person:alex"])
            == "Assign ISSUE-7 to Alex")
    #expect(HumanText.action(kind: "archive", target: "inbox:MSG-9") == "Archive MSG-9")
    #expect(HumanText.adapter("fake-triage") == "Triage (test)")
}

@Test func earlierRunsListTheStewardsFinishedRunsNewestFirst() {
    let events = PreviewFixtures.live(now: FeatureTestClock.now)
    let steward = events.first { $0.run == PreviewFixtures.inProgressRun }?.steward
    let runs = EarlierRun.list(
        events: events, steward: steward, excluding: PreviewFixtures.inProgressRun)
    #expect(runs.map(\.id) == ["run_h2", "run_h1"])
    #expect(runs.first?.steps == 5)
    #expect(runs.first?.meta.hasPrefix("5 steps · ") == true)
}

@Test func checksSettleActionsInlineAndRefusedStepsSayWhy() throws {
    let events = PreviewFixtures.checked(now: FeatureTestClock.now)
    let stream = RunStream.build(events: events, run: PreviewFixtures.checkedRun)
    let actions = stream.steps.compactMap { step -> (StreamStep, ProposedActionStep)? in
        if case .action(let action) = step.kind { return (step, action) }
        return nil
    }
    try #require(actions.count == 3)
    let (labelStep, label) = actions[0]
    #expect(label.check?.text(since: labelStep.at) == "✓ resolved after 4 d")
    let (closeStep, close) = actions[2]
    #expect(close.check?.text(since: closeStep.at) == "✗ reopened after 2 d")
    let refund = actions[1].1
    #expect(RunThreadText.failed(refund))
    #expect(
        RunThreadText.actionNote(refund)
            == "refused: Priya has no use grant for refund on billing")
    let brief = RunBrief.build(stream: stream, events: events, expected: nil)
    #expect(brief.plan.map(\.mark) == [.done, .done, .blocked, .done])
    #expect(ActionCheck.span(90) == "1 min")
    #expect(ActionCheck.span(5 * 3600) == "5 h")
}

@Test func everyActionKindApprovesWithAVerbNeverABareNoun() {
    let kinds = [
        "label", "assign", "reply", "route", "refund", "close", "comment", "send_email", "mark",
        "post", "note", "routine", "message", "email", "invoice", "webhook", "set_priority",
        "follow-up", "handoff", "escalation", "archive", "notify", "report", "ticket",
    ]
    for kind in kinds + Array(HumanText.nounEffects.keys) {
        let label = HumanText.approveLabel(kind: kind)
        let effect = String(label.dropFirst("Approve and ".count))
        let first = effect.split(separator: " ").first.map(String.init) ?? ""
        #expect(label.hasPrefix("Approve and "), "\(kind): \(label)")
        #expect(HumanText.verbs.contains(first), "\(kind) reads \(label)")
    }
    #expect(HumanText.approveLabel(kind: "routine") == "Approve and run the routine")
    #expect(
        HumanText.approveLabel(kind: "routine", params: ["version": "1a2b3c"])
            == "Approve and update the routine")
    #expect(HumanText.approveLabel(kind: "webhook") == "Approve and call the webhook")
    #expect(HumanText.approveLabel(kind: "frobnicator") == "Approve and carry out the frobnicator")
    #expect(HumanText.approveLabel(kind: "question") == "Approve")
    #expect(
        HumanText.change(
            "input: none → ORDER-1218", kind: "routine", params: ["name": "refund-check"])
            == "Routine refund-check for ORDER-1218")
    #expect(HumanText.change("to: none → person:alex", kind: "assign") == "to: Alex")
}

@Test func theLocalOperatorReadsAsYouEverywhere() {
    for id in ["local", "human:local", "person:local"] { #expect(HumanText.actor(id) == "you") }
    #expect(HumanText.actor(FeatureActor.localUser) == "you")
    #expect(HumanText.actor(FeatureActor(kind: .human, id: "priya")) == "Priya")
    #expect(HumanText.actor("person:sam") == "Sam")
    #expect(HumanText.actor(FeatureActor(kind: .steward, id: "st_triage")) == "st_triage")
    let at = Date(timeIntervalSince1970: 1_000)
    let decision = ApprovalDecision(verdict: .granted, actor: .localUser, reason: "", at: at)
    #expect(ApprovalText.verdict(decision, now: at).hasPrefix("Approved by you"))
    #expect(GovernanceText.people(["person:sam", "local"]) == "Sam, you")
}

@Test func briefStepsReadAsWordsAndCutOnlyAtWordEnds() {
    #expect(HumanText.tool("inbox.search") == "Search the inbox")
    #expect(HumanText.tool("crm.get") == "Read the CRM")
    #expect(HumanText.tool("run_tests") == "Run tests")
    #expect(HumanText.step(kind: "label", target: "inbox:MSG-137") == "Label MSG-137")
    #expect(HumanText.step(kind: "reply", target: "person:priya") == "Reply to Priya")
    #expect(HumanText.clip("Search the inbox", max: 36) == "Search the inbox")
    #expect(
        HumanText.clip("Three similar teams bought the annual plan", max: 20)
            == "Three similar teams…")
    #expect(HumanText.clip("supercalifragilistic", max: 8) == "superca…")
    #expect(
        HumanText.clip("Edit: routines/flag-duplicate-charges.sh", max: 34)
            == "Edit: routines/flag-duplicate…")
}

@Test func threadAndPlanNameStepsInTheSameWords() {
    let call = ToolCallStep(
        callID: "t1", tool: "crm.search", input: .null, output: nil, durationSeconds: nil)
    #expect(StreamStepText.title(.toolCall(call)) == HumanText.tool("crm.search"))
    #expect(HumanText.stepVerb("reply") == "Reply to")
    #expect(HumanText.stepVerb("label") == "Label")
}
