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

/// Two open charter proposals against a live charter: one whose rehearsal made case-0005
/// worse (billing → security) and one that made case-0003 better, for tests and snapshots.
enum ProposalFixtures {
    static let regressed = "prop_regressed"
    static let passing = "prop_passing"

    static func events(live: FeatureJSON, steward: String, start: Date) -> [FeatureEvent] {
        var log = FeatureEventBuilder(start: start)
        func charter(_ outcome: String) -> FeatureJSON {
            guard case .object(var members) = live else { return live }
            members["outcome"] = .string(outcome)
            return .object(members)
        }
        func result(_ choice: String) -> FeatureJSON {
            ["decisions": [["choice": .string(choice)]]]
        }
        func rehearsal(_ id: String, _ cases: [(String, Bool, String)], proposal: String?) {
            var started: FeatureJSON = [
                "rehearsal": .string(id), "charterVersion": 1,
                "cases": .number(Double(cases.count)),
                "casebookVersion": "cb_fixture", "samples": 1,
            ]
            if let proposal, case .object(var members) = started {
                members["proposal"] = .string(proposal)
                started = .object(members)
            }
            log.add("rehearsal.started", steward: steward, started)
            for (caseID, passed, choice) in cases {
                log.add(
                    "rehearsal.case.scored", steward: steward,
                    [
                        "rehearsal": .string(id), "case": .string(caseID), "runs": [],
                        "scores": [["value": passed ? 1 : 0, "passed": .bool(passed)]],
                        "results": [result(choice)],
                    ])
            }
        }
        func gated(_ proposal: String, _ baseline: String, _ candidate: String, passed: Bool) {
            log.add(
                "proposal.gated", steward: steward,
                [
                    "proposal": .string(proposal), "baseline": .string(baseline),
                    "candidate": .string(candidate), "casebook": "cb_fixture",
                    "verdict": [
                        "passed": .bool(passed), "baselineMean": 0.875,
                        "candidateMean": passed ? 1 : 0.75,
                        "regressions": passed ? [] : ["case-0005"],
                        "reason": passed ? "no regressions" : "case regressed",
                    ],
                ])
        }
        let base = (1...8).map { ("case-000\($0)", $0 != 3, $0 == 5 ? "billing" : "question") }
        rehearsal("reh_live", base, proposal: nil)
        log.add(
            "proposal.created", steward: steward,
            [
                "proposal": .string(regressed), "kind": "charter", "baseVersion": 1,
                "candidateVersion": 2,
                "charter": charter("Every security report reaches the security queue first."),
                "reason": .string(
                    "Route security reports before billing\nSecurity reports were waiting behind "
                        + "billing questions."),
            ])
        rehearsal(
            "reh_regressed",
            base.map { $0.0 == "case-0005" ? ($0.0, false, "security") : $0 }, proposal: regressed)
        gated(regressed, "reh_live", "reh_regressed", passed: false)
        log.add(
            "proposal.created", steward: steward,
            [
                "proposal": .string(passing), "kind": "charter", "baseVersion": 1,
                "candidateVersion": 2,
                "charter": charter("Feature requests are labeled and routed within a day."),
                "reason": "Label feature requests\nThey were being left unlabeled.",
            ])
        rehearsal(
            "reh_passing", base.map { $0.0 == "case-0003" ? ($0.0, true, "feature") : $0 },
            proposal: passing)
        gated(passing, "reh_live", "reh_passing", passed: true)
        return log.events
    }
}
