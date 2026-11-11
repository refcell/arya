import AryaAdapters
import AryaCore
import AryaLedger
import AryaRuntime
import Foundation
import Testing

@testable import Arya

/// The first update within `seconds`, or nil.
private func first(
    _ stream: AsyncStream<LiveUpdate>, within seconds: Double = 20,
    where accept: @escaping @Sendable (LiveUpdate) -> Bool = { _ in true }
) async -> LiveUpdate? {
    await withTaskGroup(of: LiveUpdate?.self) { group in
        group.addTask {
            for await update in stream where accept(update) { return update }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let found = await group.next() ?? nil
        group.cancelAll()
        return found
    }
}

@Test func observingAnEndedRunReplaysItsStepsAndEnds() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let run = try await workspace.startRun(steward: "st_inbox", input: "Sort MSG-9")

    var updates: [LiveUpdate] = []
    for await update in workspace.observe(run: run.id) { updates.append(update) }
    let update = try #require(updates.first)
    #expect(updates.count == 1)
    #expect(update.status == .finished)
    #expect(update.progress == 1)
    let kinds = update.steps.map(\.kind)
    #expect(kinds.first == "started")
    #expect(kinds.last == "finished")
    #expect(kinds.contains("decision"))
    #expect(update.steps.contains { $0.title == "Decided billing" })
    #expect(update.steps.contains { $0.kind == "action" && $0.title.hasPrefix("Proposed label") })
    // Steps are the rows the user sees: not the start, the end, or the decision.
    #expect(update.stepCount == update.steps.filter(\.isVisible).count)
    #expect(update.stepCount < update.steps.count)
    #expect(update.steps.first { $0.kind == "decision" }?.isVisible == false)
    #expect(update.steps.first?.text == "Sort MSG-9")
}

@Test func observingAStewardStreamsNewRunsFromTheLedgerFile() async throws {
    let opened = try await Opened([
        FakeScript.Run(result: liveResult), FakeScript.Run(result: liveResult),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let earlier = try await workspace.startRun(steward: "st_inbox", input: "First")

    // A one-minute fallback poll: the update can only arrive in time through the file watch.
    let id = StewardID(unchecked: "st_inbox")
    let stream = workspace.observe(endsWithRun: false, fallback: .seconds(60)) {
        $0.steward == id
    }
    let caughtUp = await first(stream, within: 5) { $0.run == earlier.id }
    #expect(caughtUp?.status == .finished)

    async let fresh = first(stream) { $0.run != earlier.id && $0.status == .finished }
    try await Task.sleep(for: .milliseconds(200))
    let later = try await workspace.startRun(steward: "st_inbox", input: "Second")
    let update = await fresh
    #expect(update?.run == later.id)
    #expect(update?.steps.last?.kind == "finished")
}

@Test func liveRunsListsRunsInProgressWithAnEstimate() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    #expect(try await workspace.liveRuns().isEmpty)
    let done = try await workspace.startRun(steward: "st_inbox", input: "First")

    // A run that started and has not ended: the same start, under a new run id.
    var started: Event?
    try workspace.reader.forEach { event in
        if event.run?.rawValue == done.id, event.type.rawValue == RunEventType.started {
            started = event
        }
    }
    let start = try #require(started)
    _ = try await workspace.sink.append(
        RuntimeEventDraft(
            type: RunEventType.started, steward: start.steward, run: RunID(unchecked: "run_live"),
            actor: .localUser, payload: start.payload))

    let live = try await workspace.liveRuns()
    #expect(live.map(\.run.id) == ["run_live"])
    let run = try #require(live.first)
    // Only the start so far: no visible step yet.
    #expect(run.stepCount == 0)
    #expect(run.lastStep == "Started")
    let finished = try #require(await workspace.observe(run: done.id).first { _ in true })
    #expect(finished.stepCount > 0)
    #expect(run.progress == 0)
    #expect(run.estimatedSteps == finished.stepCount)
    #expect(run.stewardName == (try await workspace.stewards().first?.name))
}

@Test func observingShowsRuntimeToolStepsOnceWithStreamedOutput() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let done = try await workspace.startRun(steward: "st_inbox", input: "First")
    var started: Event?
    try workspace.reader.forEach { event in
        if event.run?.rawValue == done.id, event.type.rawValue == RunEventType.started {
            started = event
        }
    }
    let start = try #require(started)
    let run = RunID(unchecked: "run_steps")
    func add(_ type: String, _ payload: JSONValue) async throws {
        _ = try await workspace.sink.append(
            RuntimeEventDraft(
                type: type, steward: start.steward, run: run, actor: .localUser,
                payload: payload))
    }
    try await add(RunEventType.started, start.payload)
    try await add(
        StepEventType.started.rawValue, ["step": "c1", "tool": "search", "input": "MSG-9"])
    for (index, chunk) in ["first part, ", "second part"].enumerated() {
        try await add(
            StepEventType.output.rawValue,
            [
                "step": "c1", "seq": .string(String(index + 1)), "text": .string(chunk),
                "bytes": "11",
            ])
    }
    try await add(
        StepEventType.finished.rawValue,
        ["step": "c1", "ok": true, "bytes": "23", "chunks": "2", "millis": 42])

    var updates = workspace.observe(run: "run_steps").makeAsyncIterator()
    let update = try #require(await updates.next())
    #expect(update.status == .running)
    #expect(
        update.steps.map(\.kind) == ["started", "tool_call", "output", "output", "tool_result"])
    #expect(update.steps[1].title == "Called search")
    #expect(update.steps[2...3].compactMap(\.text).joined() == "first part, second part")
    #expect(update.steps[4].title == "Tool done in 42 ms")
}

@Test func runFactsLiveRunsAndStewardLiveAgree() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let done = try await workspace.startRun(steward: "st_inbox", input: "First")

    let finished = try #require(try await workspace.runFacts(run: done.id))
    #expect(finished.status == "finished")
    #expect(finished.decisions == 1)
    #expect(finished.actionsProposed == 3)
    #expect(finished.actionsApplied + finished.actionsDrafted == 2)
    #expect(finished.actionsWaiting == 1)
    #expect(finished.progress == 1)
    #expect(finished.ended != nil)
    #expect(try await workspace.runFacts(run: "run_missing") == nil)

    var started: Event?
    try workspace.reader.forEach { event in
        if event.run?.rawValue == done.id, event.type.rawValue == RunEventType.started {
            started = event
        }
    }
    let start = try #require(started)
    _ = try await workspace.sink.append(
        RuntimeEventDraft(
            type: RunEventType.started, steward: start.steward, run: RunID(unchecked: "run_live"),
            actor: .localUser, payload: start.payload))

    let facts = try #require(try await workspace.runFacts(run: "run_live"))
    let live = try #require(try await workspace.liveRuns().first)
    let steward = try await workspace.stewardLive(steward: "st_inbox")
    #expect(facts.status == "running" && facts.ended == nil)
    #expect(live.run.id == "run_live" && steward.running?.run == "run_live")
    #expect(facts.stepIndex == live.stepCount && steward.running?.stepIndex == live.stepCount)
    #expect(facts.progress == live.progress && steward.running?.progress == live.progress)
    #expect(facts.estimatedSteps == live.estimatedSteps)
    #expect(facts.estimatedSteps == finished.stepIndex)
    #expect(abs(facts.elapsedSeconds - live.elapsedSeconds) < 2)
    #expect(steward.alsoRunning == 0)
    #expect(steward.schedule == "off" || steward.schedule == "unscheduled")
}

@Test func finishedRunsShowStepsDoneAndRunningEstimatesNeverTrailTheSteps() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let done = try await workspace.startRun(steward: "st_inbox", input: "First")
    let finished = try #require(try await workspace.runFacts(run: done.id))
    // Finished: steps done, no estimate (no "step 34 of ~14").
    #expect(finished.estimatedSteps == nil)
    #expect(finished.stepIndex > 0 && finished.progress == 1)

    var started: Event?
    try workspace.reader.forEach { event in
        if event.run?.rawValue == done.id, event.type.rawValue == RunEventType.started {
            started = event
        }
    }
    let start = try #require(started)
    let live = RunID(unchecked: "run_long")
    _ = try await workspace.sink.append(
        RuntimeEventDraft(
            type: RunEventType.started, steward: start.steward, run: live, actor: .localUser,
            payload: start.payload))
    let usual = finished.stepIndex
    #expect(try await workspace.runFacts(run: live.rawValue)?.estimatedSteps == usual)
    for index in 0..<(usual + 3) {
        _ = try await workspace.sink.append(
            RuntimeEventDraft(
                type: StepEventType.started.rawValue, steward: start.steward, run: live,
                actor: .localUser, payload: ["step": .string("s\(index)"), "tool": "search"]))
    }
    let facts = try #require(try await workspace.runFacts(run: live.rawValue))
    #expect(facts.stepIndex > usual)
    #expect(facts.estimatedSteps == facts.stepIndex + 1)
    #expect(try await workspace.liveRuns().first?.estimatedSteps == facts.stepIndex + 1)
}

@Test func runHistoryCountsLiveRunsPerDayAndKeepsRehearsalsApart() async throws {
    let opened = try await Opened([
        FakeScript.Run(result: liveResult), FakeScript.Run(result: liveResult),
    ])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    _ = try await workspace.startRun(steward: "st_inbox", input: "First")
    _ = try await workspace.startRun(steward: "st_inbox", input: "Second")
    let history = try await workspace.runHistory(steward: "st_inbox")
    #expect(history.days.count == 7)
    #expect(history.days.last?.runs == 2 && history.today == 2 && history.total == 2)
    #expect(history.days.dropLast().allSatisfy { $0.runs == 0 })
    #expect(history.days.reduce(0) { $0 + $1.rehearsals } == 0)
    #expect(history.line == "2 runs in 7 days, 2 today")
    #expect(try await workspace.runHistory(days: 3).days.count == 3)
    await #expect(throws: WorkspaceError.self) {
        try await workspace.runHistory(steward: "st_missing")
    }
}

@Test func servingIsOneRuleSchedulerOrALeasedRun() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let done = try await workspace.startRun(steward: "st_inbox", input: "First")
    var started: Event?
    try workspace.reader.forEach { event in
        if event.run?.rawValue == done.id, event.type.rawValue == RunEventType.started {
            started = event
        }
    }
    let start = try #require(started)
    let live = RunID(unchecked: "run_live")
    _ = try await workspace.sink.append(
        RuntimeEventDraft(
            type: RunEventType.started, steward: start.steward, run: live, actor: .localUser,
            payload: start.payload))

    // A run left running with no process behind it does not count.
    var state = try await workspace.serveState()
    #expect(!state.serving && state.reason == "off")
    #expect(try await workspace.stewardLive(steward: "st_inbox").serving == false)

    let lease = try await workspace.leases.acquire(live)
    state = try await workspace.serveState()
    #expect(state.serving && state.reason == "runs" && state.drivenRuns == ["run_live"])
    let status = try await workspace.serveStatus()
    #expect(status.serving && status.scheduler == state)
    #expect(try await workspace.stewardLive(steward: "st_inbox").serving)
    lease.release()
    #expect(try await workspace.serveState().serving == false)
}

@Test func runFactsCountTheToolRecordsTheToolsTabLists() async throws {
    let opened = try await Opened([FakeScript.Run(result: liveResult)])
    let workspace = opened.workspace
    _ = try await workspace.createSteward(charter: try inboxCharterJSON())
    let done = try await workspace.startRun(steward: "st_inbox", input: "First")
    var started: Event?
    try workspace.reader.forEach { event in
        if event.run?.rawValue == done.id, event.type.rawValue == RunEventType.started {
            started = event
        }
    }
    let start = try #require(started)
    func add(_ run: String, _ type: String, _ payload: JSONValue) async throws {
        _ = try await workspace.sink.append(
            RuntimeEventDraft(
                type: type, steward: start.steward, run: RunID(unchecked: run),
                actor: .localUser, payload: payload))
    }

    // The binding proxy's records: two calls, one result.
    try await add("run_proxy", RunEventType.started, start.payload)
    try await add("run_proxy", "run.tool.call", ["id": "t1", "tool": "inbox.get"])
    try await add("run_proxy", "run.tool.result", ["id": "t1", "isError": false])
    try await add("run_proxy", "run.tool.call", ["id": "t2", "tool": "billing.order"])
    var facts = try #require(try await workspace.runFacts(run: "run_proxy"))
    #expect(facts.status == "running" && facts.toolCalls == 2)
    var observed = workspace.observe(run: "run_proxy").makeAsyncIterator()
    var update = try #require(await observed.next())
    #expect(update.steps.filter { $0.kind == "tool_call" }.count == facts.toolCalls)

    // The runtime's step records win once the run has them, as on the TOOLS tab.
    try await add("run_steps", RunEventType.started, start.payload)
    for id in ["c1", "c2", "c3"] {
        try await add(
            "run_steps", StepEventType.started.rawValue,
            ["step": .string(id), "tool": "search", "input": "MSG-9"])
        try await add(
            "run_steps", StepEventType.finished.rawValue,
            ["step": .string(id), "ok": true, "bytes": "1", "chunks": "1", "millis": 5])
    }
    facts = try #require(try await workspace.runFacts(run: "run_steps"))
    #expect(facts.toolCalls == 3)
    observed = workspace.observe(run: "run_steps").makeAsyncIterator()
    update = try #require(await observed.next())
    #expect(update.steps.filter { $0.kind == "tool_call" }.count == 3)
    try await add("run_proxy", StepEventType.started.rawValue, ["step": "c9", "tool": "search"])
    #expect(try await workspace.runFacts(run: "run_proxy")?.toolCalls == 1)
}
