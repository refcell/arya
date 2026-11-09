import Foundation

/// Builds a fixture event log with sequential `seq`, ids, and times.
struct FeatureEventBuilder {
    private(set) var events: [FeatureEvent] = []
    private var clock: Date

    init(start: Date) { clock = start }

    /// Appends one event `seconds` after the previous one.
    mutating func add(
        _ type: String, steward: String? = PreviewFixtures.steward, run: String? = nil,
        actor: FeatureActor? = nil, after seconds: Double = 5, _ payload: FeatureJSON = [:]
    ) {
        clock = clock.addingTimeInterval(seconds)
        let seq = events.count + 1
        let who = actor ?? FeatureActor(kind: .steward, id: steward ?? "arya")
        events.append(
            FeatureEvent(
                seq: seq, id: "ev_\(seq)", at: clock, steward: steward, run: run, actor: who,
                type: type, payload: payload,
                hash: String(repeating: String(seq % 10), count: 64)))
    }
}

/// Sample data: a generic issue-triage steward with one finished run (a tool call, a
/// decision, an automatic label, and an assignment waiting for approval) and one live run.
enum PreviewFixtures {
    static let steward = "st_triage"
    static let finishedRun = "run_0001"
    static let liveRun = "run_0002"
    static let pendingApproval = "ap_0001"
    static let passingProposal = "pr_0001"
    static let failingProposal = "pr_0002"
    static let stewardNote = "note_0001"
    static let correctionNote = "note_0002"
    static let routineName = "label-duplicates"
    static let routineV1 = "sha256:1a2b3c"
    static let routineV2 = "sha256:4d5e6f"
    static let rehearsal = "rh_0001"
    static let casebook = "sha256:cb0001"
    static let failingCase = "case-0007"

    /// Expected results by `casebook/case`, standing in for the casebook blob.
    static let expectedResults: [String: FeatureJSON] = [
        "\(casebook)/case-0003": [
            "decisions": [["choice": "question"]],
            "actions": [["kind": "label", "target": "tracker:ISSUE-3"]],
        ],
        "\(casebook)/\(failingCase)": [
            "decisions": [["choice": "bug"]],
            "actions": [["kind": "label", "target": "tracker:ISSUE-7"]],
        ],
    ]

    /// Routine bodies by version, standing in for the blob store.
    static let routineBodies: [String: String] = [
        routineV1: "#!/bin/sh\n# Label issues whose title matches an open one.\n"
            + "tracker search --open --title \"$1\"\nexit 0\n",
        routineV2: "#!/bin/sh\n# Label issues whose title matches an open one.\n"
            + "tracker search --open --title \"$1\" --limit 5\ntracker label duplicate\n"
            + "exit 0\n",
    ]

    static func triage(now: Date) -> [FeatureEvent] {
        var log = FeatureEventBuilder(start: now.addingTimeInterval(-3600))
        let human = FeatureActor.localUser
        let adapter = FeatureActor(kind: .adapter, id: "fake")
        log.add("steward.created", actor: human, ["name": "Issue triage", "version": 1])
        finished(&log, adapter: adapter)
        let live = liveRun
        log.add("run.started", run: live, after: 1200, ["trigger": "interval"])
        proposals(&log)
        memory(&log)
        routines(&log)
        rehearsal(&log)
        log.add(
            "run.adapter.event", run: live, actor: adapter,
            wire(1, ["kind": "status", "state": "working", "detail": "Reading new issues"]))
        log.add(
            "run.adapter.event", run: live, actor: adapter,
            wire(
                2,
                [
                    "kind": "tool_call", "id": "t2", "tool": "tracker.search",
                    "input": ["query": "is:open label:none"],
                ]))
        return log.events
    }

    private static func finished(_ log: inout FeatureEventBuilder, adapter: FeatureActor) {
        let run = finishedRun
        log.add("run.started", run: run, after: 60, ["trigger": "manual"])
        log.add(
            "run.adapter.event", run: run, actor: adapter,
            ["direction": "out", "message": ["jsonrpc": "2.0", "id": 1, "method": "run/start"]])
        log.add(
            "run.adapter.event", run: run, actor: adapter,
            wire(1, ["kind": "message", "role": "assistant", "text": "Reading ISSUE-7."]))
        log.add(
            "run.adapter.event", run: run, actor: adapter,
            wire(
                2,
                [
                    "kind": "tool_call", "id": "t1", "tool": "tracker.get",
                    "input": ["id": "ISSUE-7"],
                ]))
        log.add(
            "run.adapter.event", run: run, actor: adapter, after: 1.2,
            wire(
                3,
                [
                    "kind": "tool_result", "id": "t1", "isError": false,
                    "output": ["title": "Login page times out", "labels": []],
                ]))
        log.add(
            "run.decision", run: run,
            [
                "id": "d1", "choice": "bug",
                "rationale": "The report describes a timeout on an existing page.",
                "alternatives": ["question", "feature"],
            ])
        actions(&log, run: run)
        log.add(
            "run.finished", run: run,
            ["status": "completed", "summary": "Labeled ISSUE-7 and asked to assign it."])
    }

    /// A rehearsal of charter v1 on three cases: one pass, one miss, one leak.
    private static func rehearsal(_ log: inout FeatureEventBuilder) {
        let system = FeatureActor(kind: .system, id: "arya")
        log.add(
            "rehearsal.started", actor: .localUser, after: 30,
            [
                "v": 1, "rehearsal": .string(rehearsal), "charterVersion": 1,
                "casebookVersion": .string(casebook), "cases": 3, "samples": 1,
            ])
        rehearsalRun(&log, run: "run_r3", choice: "question", target: "tracker:ISSUE-3")
        log.add(
            "rehearsal.case.scored", actor: system,
            [
                "v": 1, "rehearsal": .string(rehearsal), "case": "case-0003", "runs": ["run_r3"],
                "scores": [["value": 1, "passed": true, "notes": []]], "leak": false,
            ])
        rehearsalRun(&log, run: "run_r7", choice: "question", target: "tracker:ISSUE-7")
        log.add(
            "rehearsal.case.scored", actor: system,
            [
                "v": 1, "rehearsal": .string(rehearsal), "case": .string(failingCase),
                "runs": ["run_r7"],
                "scores": [
                    [
                        "value": 0.5, "passed": false,
                        "notes": ["decisions.choice: expected bug, got question"],
                    ]
                ],
                "leak": false,
            ])
        log.add(
            "rehearsal.case.scored", actor: system,
            [
                "v": 1, "rehearsal": .string(rehearsal), "case": "case-0009", "runs": [nil],
                "scores": [["value": 0, "passed": false, "notes": ["unanswered tool read"]]],
                "leak": true,
            ])
        log.add(
            "rehearsal.finished", actor: system,
            ["v": 1, "rehearsal": .string(rehearsal), "meanScore": 0.5, "passed": 1, "leaks": 1])
    }

    private static func rehearsalRun(
        _ log: inout FeatureEventBuilder, run: String, choice: String, target: String
    ) {
        log.add("run.started", run: run, ["trigger": "case", "rehearsal": true])
        log.add("run.decision", run: run, ["id": "d1", "choice": .string(choice)])
        log.add(
            "action.proposed", run: run,
            [
                "action": ["id": "a1", "kind": "label", "target": .string(target)],
                "disposition": "auto", "reason": "auto label",
            ])
        log.add("run.finished", run: run, ["status": "completed", "summary": ""])
    }

    private static func routines(_ log: inout FeatureEventBuilder) {
        let system = FeatureActor(kind: .system, id: "arya")
        log.add(
            "routine.proposed", run: finishedRun, after: 5,
            [
                "v": 1, "name": .string(routineName), "version": .string(routineV1),
                "language": "sh", "bytes": 82, "summary": "Find likely duplicates",
                "run": .string(finishedRun),
            ])
        log.add(
            "routine.promoted", actor: system, after: 60,
            ["v": 1, "name": .string(routineName), "version": .string(routineV1)])
        log.add(
            "routine.proposed", run: finishedRun, after: 5,
            [
                "v": 1, "name": .string(routineName), "version": .string(routineV2),
                "language": "sh", "bytes": 115, "summary": "Label duplicates directly",
                "reason": "Duplicates come up in most runs.", "run": .string(finishedRun),
            ])
    }

    private static func memory(_ log: inout FeatureEventBuilder) {
        log.add(
            "memory.added", run: finishedRun, after: 5,
            [
                "v": 1,
                "note": [
                    "id": .string(stewardNote), "text": "Login issues usually belong to Alex.",
                    "tags": ["routing", "login"],
                    "provenance": [
                        "run": .string(finishedRun), "event": "ev_6",
                        "author": ["kind": "steward", "id": .string(steward)],
                    ],
                ],
            ])
        log.add(
            "memory.added", actor: .localUser, after: 20,
            [
                "v": 1,
                "note": [
                    "id": .string(correctionNote),
                    "text": "Timeouts on the login page are bugs, not questions.",
                    "tags": ["labels"],
                    "provenance": [
                        "case": "case-0007", "author": ["kind": "human", "id": "local"],
                    ],
                ],
            ])
    }

    private static func proposals(_ log: inout FeatureEventBuilder) {
        let system = FeatureActor(kind: .system, id: "arya")
        log.add(
            "proposal.created", actor: .localUser, after: 30,
            [
                "id": .string(passingProposal), "kind": "charter", "candidateVersion": 2,
                "title": "Ask before labeling security reports",
                "reason": "Security reports need a person's eyes first.",
            ])
        log.add(
            "proposal.gated", actor: system, after: 40,
            [
                "proposal": .string(passingProposal), "passed": true, "baselineMean": 0.9,
                "candidateMean": 0.92, "regressions": [], "reason": "no regression",
            ])
        log.add(
            "proposal.created", run: finishedRun, after: 10,
            [
                "id": .string(failingProposal), "kind": "routine", "title": "label-duplicates",
                "reason": "Duplicates come up in most runs.",
            ])
        log.add(
            "proposal.gated", actor: system, after: 40,
            [
                "proposal": .string(failingProposal), "passed": false, "baselineMean": 0.9,
                "candidateMean": 0.8, "regressions": ["case-0003", "case-0007"],
                "reason": "2 cases regressed",
            ])
    }

    /// A recorded `run/event` notification, as the runtime stores it in `run.adapter.event`.
    static func wire(_ seq: Int, _ event: FeatureJSON) -> FeatureJSON {
        [
            "direction": "in",
            "message": [
                "jsonrpc": "2.0", "method": "run/event",
                "params": ["session": "s1", "seq": .number(Double(seq)), "event": event],
            ],
        ]
    }

    private static func actions(_ log: inout FeatureEventBuilder, run: String) {
        let system = FeatureActor(kind: .system, id: "arya")
        let label: FeatureJSON = [
            "id": "a1", "kind": "label", "binding": "tracker", "target": "tracker:ISSUE-7",
            "rationale": "Bugs get the bug label.",
        ]
        let assign: FeatureJSON = [
            "id": "a2", "kind": "assign", "binding": "tracker", "target": "tracker:ISSUE-7",
            "params": ["to": "person:alex"], "rationale": "Alex owns the login page.",
        ]
        log.add(
            "action.proposed", run: run, actor: system,
            ["action": label, "disposition": "auto", "reason": "auto label"])
        log.add(
            "action.executed", run: run, actor: system, ["action": "a1", "output": "labeled"])
        log.add(
            "action.proposed", run: run, actor: system,
            ["action": assign, "disposition": "ask", "reason": "default ask"])
        log.add(
            "approval.requested", run: run,
            [
                "approval": .string(pendingApproval), "kind": "action", "action": assign,
                "to": "local",
            ])
    }
}
