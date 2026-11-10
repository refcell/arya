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
    #expect(progress.done == RunThreadText.visible(stream.steps).count)
    #expect(progress.text(now: now) == "4 of ~5 steps · 4.2 s")
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
    #expect(lone.text(now: now) == "3 steps · 2.0 s")
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
    #expect(
        RunStream.dryRunSummary("Moved a message to spam.")
            == "Dry run: would have moved a message to spam.")
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
