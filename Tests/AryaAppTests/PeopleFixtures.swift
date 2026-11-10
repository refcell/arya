import Foundation

@testable import AryaApp

/// A conversation between a person and a steward, shaped like the runtime records it, for the
/// `people-thread` snapshot and tests: a question and the steward's reply, a correction, a
/// hand-off its run finished, a weekly report, a hand-off whose run waits on an approval, and
/// one whose run is still going.
enum PeopleFixtures {
    /// Only a new hand-off and its run still going, for the `people-thread-live` snapshot over
    /// the demo home: no approvals or reports, so every count stays the workspace's own.
    static func live(steward: String, person: String, start: Date) -> [FeatureEvent] {
        var log = FeatureEventBuilder(start: start)
        log.add(
            "inbox.message", steward: steward, actor: FeatureActor(kind: .human, id: person),
            after: 0,
            [
                "from": .string(person), "channel": "inbox", "intent": "handoff",
                "text": "Pull the export crash reports from this week into one list.",
            ])
        let message = log.events.last?.id ?? ""
        log.add(
            "run.started", steward: steward, run: "run_live", after: 1,
            [
                "input": [
                    "kind": "message", "text": "\(person) hands this to you: export crashes",
                    "attachments": [
                        ["kind": "inbox", "message": .string(message), "from": .string(person)]
                    ],
                ]
            ])
        for event: FeatureJSON in [
            ["kind": "status", "state": "working", "detail": "reading the crash reports"],
            ["kind": "tool_call", "id": "t1", "tool": "inbox.search"],
        ] {
            log.add(
                "run.adapter.event", steward: steward, run: "run_live", after: 2,
                ["message": ["method": "run/event", "params": ["event": event]]])
        }
        return log.events
    }

    static func events(steward: String, person: String, start: Date) -> [FeatureEvent] {
        var log = FeatureEventBuilder(start: start)
        let who = FeatureActor(kind: .human, id: person)
        func message(_ text: String, _ intent: String) -> String {
            log.add(
                "inbox.message", steward: steward, actor: who, after: 600,
                [
                    "from": .string(person), "channel": "inbox", "intent": .string(intent),
                    "text": .string(text),
                ])
            return log.events.last?.id ?? ""
        }
        func run(_ id: String, for message: String) {
            log.add(
                "run.started", steward: steward, run: id, after: 2,
                [
                    "input": [
                        "kind": "message", "text": "Message from \(person)",
                        "attachments": [
                            ["kind": "inbox", "message": .string(message), "from": .string(person)]
                        ],
                    ]
                ])
        }
        func reply(_ id: String, _ text: String) {
            log.add(
                "action.executed", steward: steward, run: id, after: 40,
                [
                    "action": "reply",
                    "output": [
                        "inbox": .string(person), "channel": "inbox",
                        "params": ["text": .string(text)],
                    ],
                ])
        }
        let ask = message("Why did MSG-202 go to shipping and not billing?", "ask")
        run("run_pt1", for: ask)
        reply("run_pt1", "It asks where a package is, so shipping owns it; no charge is mentioned.")
        log.add("run.finished", steward: steward, run: "run_pt1", after: 2, [:])
        _ = message(
            "Duplicate charges always go to billing, even when shipping is mentioned.", "correct")
        let done = message("Take MSG-205 and close it out with the customer.", "handoff")
        run("run_pt2", for: done)
        reply("run_pt2", "Done: refunded the duplicate and replied to the customer on MSG-205.")
        log.add("run.finished", steward: steward, run: "run_pt2", after: 2, [:])
        log.add(
            "report.sent", steward: steward, actor: FeatureActor(kind: .system, id: "arya"),
            after: 900,
            [
                "cadence": "weekly", "since": 0, "through": 0, "days": 7,
                "text": .string(
                    "Weekly report: Inbox triage.\nrouting accuracy 0.92 against a target of 0.90 "
                        + "(on track), up from 0.85 a week ago.\n"
                        + "Did: 9 runs, 9 decisions, 14 actions."
                ),
                "to": [["person": .string(person), "channel": "inbox"]],
            ])
        let waiting = message(
            "Please refund order 4417; the customer was charged twice.", "handoff")
        run("run_pt3", for: waiting)
        log.add(
            "approval.requested", steward: steward, run: "run_pt3", after: 20,
            ["approval": "ap_pt3", "action": ["kind": "refund", "target": "order:4417"]])
        let crash = message("Also look at the export crash reports when you can.", "handoff")
        // Still going: the working line shows what the steward is doing now.
        run("run_pt4", for: crash)
        func adapter(_ event: FeatureJSON) {
            log.add(
                "run.adapter.event", steward: steward, run: "run_pt4", after: 3,
                ["message": ["method": "run/event", "params": ["event": event]]])
        }
        adapter(["kind": "status", "state": "working", "detail": "reading the crash reports"])
        adapter(["kind": "tool_call", "id": "t1", "tool": "inbox.search"])
        return log.events
    }
}
