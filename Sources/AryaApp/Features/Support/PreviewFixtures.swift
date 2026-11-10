import Foundation

/// Builds a fixture event log with sequential `seq`, ids, and times.
struct FeatureEventBuilder {
    private(set) var events: [FeatureEvent] = []
    private var clock: Date

    init(start: Date) { clock = start }

    /// Appends one event `seconds` after the previous one.
    /// Pass `at` to stamp a specific time without moving the builder's clock.
    mutating func add(
        _ type: String, steward: String? = PreviewFixtures.steward, run: String? = nil,
        actor: FeatureActor? = nil, after seconds: Double = 5, at: Date? = nil,
        _ payload: FeatureJSON = [:]
    ) {
        if at == nil { clock = clock.addingTimeInterval(seconds) }
        let stamp = at ?? clock
        let seq = events.count + 1
        let who = actor ?? FeatureActor(kind: .steward, id: steward ?? "arya")
        events.append(
            FeatureEvent(
                seq: seq, id: "ev_\(seq)", at: stamp, steward: steward, run: run, actor: who,
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
    /// A question from the live run to the `person:alex` binding.
    static let question = "ap_0002"
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
        log.add("steward.created", actor: human, ["charter": charter, "version": 1])
        metrics(&log, now: now)
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
        log.add(
            "approval.requested", run: live,
            [
                "approval": .string(question), "kind": "question",
                "question": "Is ISSUE-9 a duplicate of ISSUE-4, or a new bug?", "to": "person:alex",
            ])
        OutcomeFixtures.plan(&log)
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
                "decision": [
                    "id": "d1", "choice": "bug",
                    "rationale": "The report describes a timeout on an existing page.",
                    "alternatives": ["question", "feature"],
                ]
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
                "results": [
                    [
                        "decisions": [["choice": "question"]],
                        "actions": [["kind": "label", "target": "tracker:ISSUE-7"]],
                        "summary": "asked for details", "priority": "low",
                    ]
                ],
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
        log.add("run.decision", run: run, ["decision": ["id": "d1", "choice": .string(choice)]])
        log.add(
            "action.proposed", run: run,
            [
                "action": ["id": "a1", "kind": "label", "target": .string(target)],
                "disposition": "auto", "reason": "auto label",
            ])
        log.add("run.finished", run: run, ["status": "completed", "summary": ""])
    }

    /// The fixture steward's charter, in the JSON shape of ARCHITECTURE.md.
    static let charter: FeatureJSON = [
        "v": 1, "id": .string(steward), "name": "Issue triage",
        "outcome": "Every new issue in the tracker is labeled and routed within one hour.",
        "metric": [
            "name": "triaged_within_1h", "unit": "ratio", "direction": "up", "target": 0.95,
        ],
        "guardrails": ["Never close an issue.", "Ask before assigning to a person."],
        "bindings": [
            [
                "id": "tracker", "kind": "mcp", "command": "tracker-mcp", "args": [],
                "read": ["search", "get"], "actions": ["label", "comment", "assign"],
            ],
            ["id": "person:alex", "kind": "person", "channel": "inbox"],
        ],
        "triggers": [["kind": "interval", "everySeconds": 900], ["kind": "manual"]],
        "policy": [
            "default": "ask",
            "rules": [
                ["action": "label", "decision": "auto"], ["action": "close", "decision": "deny"],
            ],
        ],
        "adapter": "exec-default", "effort": "medium",
    ]

    /// Daily values of the outcome metric over the last five days, two readings a day.
    static let metricValues: [Double] = [0.82, 0.84, 0.86, 0.88, 0.87, 0.9, 0.9, 0.92, 0.93, 0.93]

    private static func metrics(_ log: inout FeatureEventBuilder, now: Date) {
        let system = FeatureActor(kind: .system, id: "arya")
        for (index, value) in metricValues.enumerated() {
            let day = Double(5 - index / 2) * 86_400
            let at = now.addingTimeInterval(-day + Double(index % 2) * 3600)
            log.add(
                "metric.recorded", actor: system, at: at,
                ["v": 1, "metric": "triaged_within_1h", "value": .number(value)])
        }
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

extension PreviewFixtures {
    static let crewRun = "run_c1"
    static let crewChild = "run_c1a"

    /// A run that hands the reply to a crew child (decision 0043): one child runs with a
    /// smaller budget and finishes in 2.1 s, a second delegation asks for an unlisted adapter
    /// and is refused, then the parent finishes.
    static func crew(now: Date) -> [FeatureEvent] {
        var log = FeatureEventBuilder(start: now.addingTimeInterval(-300))
        log.add("steward.created", actor: .localUser, ["charter": charter, "version": 1])
        log.add(
            "run.started", run: crewRun,
            [
                "input": [
                    "kind": "message", "text": "New message MSG-301: Charged twice for one order",
                ]
            ])
        log.add(
            "run.decision", run: crewRun,
            [
                "decision": [
                    "id": "d1", "choice": "billing",
                    "rationale": "A duplicate charge; a helper drafts the reply.",
                ]
            ])
        log.add(
            "run.delegated", run: crewRun,
            [
                "delegation": "dl_1", "title": "drafted the refund reply",
                "child": .string(crewChild), "adapter": "fake", "effort": "low",
                "limits": ["maxTurns": 4, "timeoutSeconds": 60, "maxCostMicros": 200_000],
            ])
        log.add(
            "run.started", run: crewChild, after: 1,
            [
                "input": ["kind": "message", "text": "Draft a reply about the duplicate charge"],
                "parent": .string(crewRun),
            ])
        log.add(
            "run.decision", run: crewChild, after: 2,
            [
                "decision": [
                    "id": "c1", "choice": "apologize and refund", "rationale": "Clear duplicate.",
                ]
            ])
        log.add(
            "run.finished", run: crewChild, after: 0.1,
            [
                "status": "completed",
                "summary": "Drafted a reply offering a refund for the second charge.",
            ])
        log.add(
            "run.delegated", run: crewRun, after: 1,
            [
                "delegation": "dl_2", "title": "checked the order history",
                "refused": "adapter_not_allowed:browser",
            ])
        log.add(
            "run.finished", run: crewRun,
            ["status": "completed", "summary": "Labeled MSG-301 as billing with a drafted reply."])
        return log.events
    }

    static let inProgressRun = "run_live"

    /// A run in progress: two finished runs for history, then a live one that has read the
    /// message, called one tool, decided, and is waiting on a second tool call.
    static func live(now: Date) -> [FeatureEvent] {
        var log = FeatureEventBuilder(start: now.addingTimeInterval(-600))
        let adapter = FeatureActor(kind: .adapter, id: "fake-triage")
        log.add("steward.created", actor: .localUser, ["charter": charter, "version": 1])
        for (index, run) in ["run_h1", "run_h2"].enumerated() {
            log.add("run.started", run: run, ["trigger": "message"])
            for step in 0..<4 {
                log.add(
                    "run.decision", run: run, after: 1,
                    [
                        "decision": [
                            "id": .string("d\(step)"), "choice": "billing", "rationale": "History.",
                        ]
                    ])
            }
            log.add(
                "run.finished", run: run, after: 1,
                ["status": "completed", "summary": .string("Earlier run \(index + 1).")])
        }
        log.add(
            "run.started", run: inProgressRun, at: now.addingTimeInterval(-4.2),
            [
                "trigger": "message", "adapter": "fake-triage", "effort": "medium",
                "input": [
                    "kind": "message", "text": "New message MSG-412: Refund for a broken lamp?",
                ],
            ])
        log.add(
            "run.adapter.event", run: inProgressRun, actor: adapter, after: 0.1,
            [
                "direction": "sent",
                "message": [
                    "jsonrpc": "2.0", "id": 1, "method": "run/start",
                    "params": ["input": "MSG-412"],
                ],
            ])
        log.add(
            "run.adapter.event", run: inProgressRun, actor: adapter, after: 0.2,
            wire(1, ["kind": "thinking", "text": "Reading the message and the order."]))
        log.add(
            "run.tool.call", run: inProgressRun, after: 0.3,
            ["id": "t1", "tool": "inbox.get", "binding": "inbox", "input": ["id": "MSG-412"]])
        log.add(
            "run.tool.result", run: inProgressRun, after: 0.4,
            [
                "id": "t1", "isError": false, "durationSeconds": 0.4,
                "output": [
                    "id": "MSG-412", "from": "customer:c-412",
                    "body":
                        "The lamp arrived broken.\nOrder ORDER-2210.\nPhoto attached.\n"
                        + "I would like a refund.\nThanks.",
                ],
            ])
        log.add(
            "run.decision", run: inProgressRun, after: 0.5,
            [
                "decision": [
                    "id": "d1", "choice": "billing",
                    "rationale": "A damaged item with an order number is a refund request.",
                ]
            ])
        log.add(
            "run.tool.call", run: inProgressRun, after: 0.3,
            [
                "id": "t2", "tool": "billing.order", "binding": "billing",
                "input": ["order": "ORDER-2210"],
            ])
        log.add(
            "run.adapter.event", run: inProgressRun, actor: adapter, after: 0.2,
            wire(2, ["kind": "tool_call", "id": "t2", "tool": "billing.order"]))
        return log.events
    }
}
