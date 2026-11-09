import Foundation

/// Preview events for the Outcome tab that the shared triage fixture does not carry yet:
/// the steward's plan, revised once, in the runtime's `plan.updated` shape.
enum OutcomeFixtures {
    /// Why the steward revised its plan.
    static let revision =
        "Closing is denied by the guardrails, so duplicates go to a person; "
        + "duplicate search repeats every run, so it becomes a routine."

    static func plan(_ log: inout FeatureEventBuilder) {
        log.add(
            "plan.updated", run: PreviewFixtures.finishedRun, after: 2,
            [
                "items": [
                    [
                        "id": "s1", "text": "Label every new issue within 15 minutes",
                        "status": "in_progress",
                    ],
                    ["id": "s2", "text": "Route login bugs to their owner", "status": "pending"],
                    ["id": "s3", "text": "Close stale duplicates", "status": "pending"],
                ],
                "reason": "First plan from the charter.",
            ])
        log.add(
            "plan.updated", run: PreviewFixtures.liveRun, after: 2,
            [
                "items": [
                    [
                        "id": "s1", "text": "Label every new issue within 15 minutes",
                        "status": "done",
                    ],
                    [
                        "id": "s2", "text": "Route login bugs to their owner",
                        "status": "in_progress",
                        "rationale": "waiting on sign-off",
                    ],
                    [
                        "id": "s4", "text": "Ask a person when a duplicate is unclear",
                        "status": "pending",
                    ],
                    [
                        "id": "s5", "text": "Write a routine for duplicate search",
                        "status": "pending",
                    ],
                ],
                "reason": .string(revision),
            ])
    }
}
