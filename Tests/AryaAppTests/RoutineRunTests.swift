import Foundation
import Testing

@testable import AryaApp

private let now = FeatureTestClock.now

private func routineAction(_ id: String) -> FeatureJSON {
    [
        "id": .string(id), "kind": "routine", "binding": "tracker", "target": "tracker:ISSUE-9",
        "params": ["name": "label-duplicates"], "rationale": "Same title as ISSUE-4.",
    ]
}

private func outcome(_ status: String, _ extra: [String: FeatureJSON] = [:]) -> FeatureJSON {
    var out: [String: FeatureJSON] = [
        "v": 1, "name": "label-duplicates", "version": "sha256:1a2b3c", "status": .string(status),
        "stdout": "", "stderr": "", "stdoutTruncated": false, "stderrTruncated": false,
    ]
    out.merge(extra) { _, new in new }
    return .object(out)
}

@Test func routineActionsCarryTheirOutcome() throws {
    var log = FeatureEventBuilder(start: now)
    log.add("run.started", run: "run_x", ["trigger": "manual"])
    for id in ["a1", "a2", "a3"] {
        log.add(
            "action.proposed", run: "run_x",
            ["action": routineAction(id), "disposition": "auto", "reason": "routine rule"])
    }
    log.add(
        "action.executed", run: "run_x",
        [
            "action": "a1",
            "output": outcome("exited", ["exitCode": 0, "stdout": "labeled ISSUE-9\n"]),
        ])
    log.add(
        "action.failed", run: "run_x",
        [
            "action": "a2", "error": "routine timed out",
            "output": outcome("timed_out", ["stdoutTruncated": true]),
        ])
    log.add(
        "action.failed", run: "run_x",
        ["action": "a3", "error": "exit 2", "output": outcome("signaled", ["signal": 9])])
    let runs = RunStream.build(events: log.events, run: "run_x").steps.compactMap { step in
        if case .action(let action) = step.kind { return action.routine } else { return nil }
    }
    #expect(runs.count == 3)
    #expect(runs[0].stdout == "labeled ISSUE-9\n")
    #expect(
        runs.map(StreamStepText.routineCaption) == [
            "routine label-duplicates · 1a2b3c · exited 0",
            "routine label-duplicates · 1a2b3c · timed out · output truncated",
            "routine label-duplicates · 1a2b3c · killed by signal 9",
        ])
}

@Test func otherActionsIgnoreOutcomeShapedOutput() {
    var log = FeatureEventBuilder(start: now)
    var label = routineAction("a1")
    if case .object(var members) = label {
        members["kind"] = "label"
        label = .object(members)
    }
    log.add("action.proposed", run: "run_x", ["action": label, "disposition": "auto"])
    log.add("action.executed", run: "run_x", ["action": "a1", "output": outcome("exited")])
    let step = RunStream.build(events: log.events, run: "run_x").steps.first
    if case .action(let action) = step?.kind {
        #expect(action.routine == nil)
    } else {
        Issue.record("expected an action step")
    }
}
