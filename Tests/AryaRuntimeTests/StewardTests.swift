import AryaCore
import Testing

@testable import AryaRuntime

func triageCharter(outcome: String = "Every new issue is labeled within one hour.") -> Charter {
    Charter(
        id: StewardID(unchecked: "st_triage"), name: "Issue triage", outcome: outcome,
        metric: Metric(name: "triaged_within_1h", unit: "ratio", direction: .up, target: 0.95),
        guardrails: ["Never close an issue."],
        bindings: [
            .mcp(
                "tracker", command: "tracker-mcp", read: ["search", "get"],
                actions: ["label", "comment", "assign"])
        ],
        policy: Policy(rules: [Policy.Rule(action: "label", decision: .auto)]),
        adapter: "fake")
}

private func makeLifecycle() -> (StewardLifecycle, MemoryEventSink) {
    let sink = MemoryEventSink(ambient: .fixed())
    return (StewardLifecycle(sink: sink), sink)
}

@Test func createRecordsCharterAtVersionOne() async throws {
    let (lifecycle, sink) = makeLifecycle()
    let record = try await lifecycle.create(triageCharter())
    #expect(record.version == 1)
    #expect(record.status == .active)
    #expect(!record.ready)
    #expect(!record.takesLiveTriggers)
    let events = try await sink.events(from: 1)
    #expect(events.map(\.type) == ["steward.created"])
    #expect(events[0].draft.actor == .localUser)
    #expect(events[0].payload.objectValue?["charter"]?.objectValue?["id"] == "st_triage")
}

@Test func duplicateAndInvalidChartersAreRejected() async throws {
    let (lifecycle, _) = makeLifecycle()
    try await lifecycle.create(triageCharter())
    await #expect(throws: StewardError.alreadyExists(StewardID(unchecked: "st_triage"))) {
        try await lifecycle.create(triageCharter())
    }
    await #expect(throws: StewardError.self) {
        try await lifecycle.updateCharter(triageCharter(outcome: "  "))
    }
}

@Test func updateBumpsVersion() async throws {
    let (lifecycle, _) = makeLifecycle()
    try await lifecycle.create(triageCharter())
    let updated = try await lifecycle.updateCharter(
        triageCharter(outcome: "Every issue is labeled within 30 minutes."), reason: "tighter")
    #expect(updated.version == 2)
    #expect(updated.charter.outcome == "Every issue is labeled within 30 minutes.")
    let again = try await lifecycle.updateCharter(triageCharter())
    #expect(again.version == 3)
}

@Test func pauseResumeRetire() async throws {
    let (lifecycle, sink) = makeLifecycle()
    let id = try await lifecycle.create(triageCharter()).id
    #expect(try await lifecycle.pause(id).status == .paused)
    await #expect(throws: StewardError.wrongStatus(id, .paused)) {
        try await lifecycle.pause(id)
    }
    #expect(try await lifecycle.resume(id).status == .active)
    #expect(try await lifecycle.retire(id, reason: "done").status == .retired)
    await #expect(throws: StewardError.wrongStatus(id, .retired)) {
        try await lifecycle.resume(id)
    }
    await #expect(throws: StewardError.wrongStatus(id, .retired)) {
        try await lifecycle.updateCharter(triageCharter())
    }
    let types = try await sink.events(from: 1).map(\.type)
    #expect(types == ["steward.created", "steward.paused", "steward.resumed", "steward.retired"])
}

@Test func unknownStewardIsNotFound() async throws {
    let (lifecycle, _) = makeLifecycle()
    let id = StewardID(unchecked: "st_missing")
    await #expect(throws: StewardError.notFound(id)) { try await lifecycle.pause(id) }
}

@Test func readyEventMakesActiveStewardLive() async throws {
    let (lifecycle, sink) = makeLifecycle()
    let id = try await lifecycle.create(triageCharter()).id
    _ = try await sink.append(
        RuntimeEventDraft(type: "steward.ready", steward: id, actor: .localUser))
    #expect(try await lifecycle.book().records[id]?.takesLiveTriggers == true)
    try await lifecycle.pause(id)
    #expect(try await lifecycle.book().records[id]?.takesLiveTriggers == false)
}

@Test func charterMapsToPolicyAndInstructions() {
    let charter = triageCharter()
    let policy = ActionPolicy(charter: charter)
    #expect(policy.classify(PolicyAction(kind: "label", binding: "tracker")).disposition == .auto)
    #expect(policy.classify(PolicyAction(kind: "assign", binding: "tracker")).disposition == .ask)
    #expect(policy.classify(PolicyAction(kind: "close", binding: "tracker")).disposition == .deny)
    let text = InstructionComposer.compose(InstructionInputs(charter: charter))
    #expect(text.contains("- tracker (mcp); read: search, get; propose: label, comment, assign"))
    #expect(text.contains("- triaged_within_1h (ratio, higher is better), target 0.95"))
}
