import Foundation

/// Preview events for the Outcome tab that the shared triage fixture does not carry yet:
/// the steward's plan, revised once, in the `plan.updated` shape the app-outcome lane
/// proposed to the workspace lane.
enum OutcomeFixtures {
    /// Why the steward revised its plan.
    static let revision =
        "Closing is denied by the guardrails, so duplicates go to a person; "
        + "duplicate search repeats every run, so it becomes a routine."

    static func plan(_ log: inout FeatureEventBuilder) {
        log.add(
            "plan.updated", run: PreviewFixtures.finishedRun, after: 2,
            [
                "v": 1,
                "steps": [
                    [
                        "id": "s1", "title": "Label every new issue within 15 minutes",
                        "status": "doing",
                    ],
                    ["id": "s2", "title": "Route login bugs to their owner", "status": "todo"],
                    ["id": "s3", "title": "Close stale duplicates", "status": "todo"],
                ],
                "reason": "First plan from the charter.",
            ])
        log.add(
            "plan.updated", run: PreviewFixtures.liveRun, after: 2,
            [
                "v": 1,
                "steps": [
                    [
                        "id": "s1", "title": "Label every new issue within 15 minutes",
                        "status": "done",
                    ],
                    [
                        "id": "s2", "title": "Route login bugs to their owner", "status": "doing",
                        "note": "waiting on sign-off",
                    ],
                    [
                        "id": "s4", "title": "Ask a person when a duplicate is unclear",
                        "status": "todo",
                    ],
                    [
                        "id": "s5", "title": "Write a routine for duplicate search",
                        "status": "todo",
                    ],
                ],
                "reason": .string(revision),
            ])
    }
}
