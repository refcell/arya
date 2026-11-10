import Foundation

/// A conversation between a person and a steward, shaped like the runtime records it, for the
/// `people-thread` snapshot and tests: a question and the steward's reply, a correction, a
/// hand-off its run finished, a weekly report, and a hand-off whose run waits on an approval.
enum PeopleFixtures {
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
                        "attachments": [["kind": "inbox", "message": .string(message)]],
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
        _ = message("Also look at the export crash reports when you can.", "handoff")
        return log.events
    }
}
